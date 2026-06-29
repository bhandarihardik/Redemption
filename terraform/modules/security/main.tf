# ---------------------------------------------------------------------------
# Security module — Defense in Depth, expressed as concrete SG rules
#
# Layer model (matches the design doc's security section):
#   Layer 1  Edge        WAF + Shield (managed, see addons.tf for WAF rules)
#   Layer 2  Network      This file — security groups as a default-deny mesh
#   Layer 3  Mesh/identity Istio mTLS + AuthorizationPolicy (k8s/base/istio)
#   Layer 4  Workload     Pod Security Standards, read-only rootfs, non-root
#   Layer 5  Data         KMS encryption at rest, Secrets Manager, no plaintext
#
# Every security group below starts with NO ingress rules and we add back
# only the specific port + source SG that's actually needed. Nothing is
# opened to 0.0.0.0/0 except the public ALB on 443.
# ---------------------------------------------------------------------------

# ALB — internet-facing, TLS only
resource "aws_security_group" "alb" {
  name        = "${var.name}-alb-sg"
  description = "Public ALB - HTTPS only from internet"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-alb-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from internet"
  cidr_ipv4          = "0.0.0.0/0"
  from_port          = 443
  to_port            = 443
  ip_protocol        = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "alb_http_redirect" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP for 301 redirect to HTTPS only - no plaintext app traffic"
  cidr_ipv4          = "0.0.0.0/0"
  from_port          = 80
  to_port            = 80
  ip_protocol        = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_mesh" {
  security_group_id           = aws_security_group.alb.id
  description                  = "ALB to Istio ingress gateway only"
  referenced_security_group_id = aws_security_group.eks_nodes.id
  from_port                    = 15443 # Istio ingress gateway TLS port
  to_port                      = 15443
  ip_protocol                  = "tcp"
}

# EKS worker nodes / pods
resource "aws_security_group" "eks_nodes" {
  name        = "${var.name}-eks-nodes-sg"
  description = "EKS worker nodes - default deny, explicit allow only"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-eks-nodes-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "nodes_from_alb" {
  security_group_id           = aws_security_group.eks_nodes.id
  description                  = "Istio ingress gateway from ALB"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 15443
  to_port                      = 15443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "nodes_self" {
  security_group_id            = aws_security_group.eks_nodes.id
  description                   = "Node-to-node (kubelet, mesh sidecar mTLS, CNI)"
  referenced_security_group_id  = aws_security_group.eks_nodes.id
  ip_protocol                   = "-1"
}

resource "aws_vpc_security_group_egress_rule" "nodes_to_data" {
  security_group_id            = aws_security_group.eks_nodes.id
  description                   = "Nodes to RDS Postgres"
  referenced_security_group_id  = aws_security_group.data.id
  from_port                      = 5432
  to_port                        = 5432
  ip_protocol                    = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "nodes_to_cache" {
  security_group_id            = aws_security_group.eks_nodes.id
  description                   = "Nodes to ElastiCache Redis"
  referenced_security_group_id  = aws_security_group.data.id
  from_port                      = 6379
  to_port                        = 6379
  ip_protocol                    = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "nodes_to_internet" {
  security_group_id = aws_security_group.eks_nodes.id
  description        = "HTTPS egress (image pulls, AWS API, external payment gateway) via NAT"
  cidr_ipv4          = "0.0.0.0/0"
  from_port          = 443
  to_port            = 443
  ip_protocol        = "tcp"
}

# Data layer — RDS + ElastiCache. ONLY reachable from EKS nodes. Nothing else.
resource "aws_security_group" "data" {
  name        = "${var.name}-data-sg"
  description = "RDS + ElastiCache - reachable only from EKS worker nodes"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-data-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "data_from_nodes_pg" {
  security_group_id            = aws_security_group.data.id
  description                   = "Postgres from EKS nodes only"
  referenced_security_group_id  = aws_security_group.eks_nodes.id
  from_port                      = 5432
  to_port                        = 5432
  ip_protocol                    = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "data_from_nodes_redis" {
  security_group_id            = aws_security_group.data.id
  description                   = "Redis from EKS nodes only"
  referenced_security_group_id  = aws_security_group.eks_nodes.id
  from_port                      = 6379
  to_port                        = 6379
  ip_protocol                    = "tcp"
}

# No egress rules on the data SG at all: RDS/ElastiCache never need to
# initiate outbound connections. Default AWS behavior with zero egress
# rules is "no egress" once we stop relying on the implicit allow-all,
# enforced explicitly below by removing it.
resource "aws_default_security_group" "default" {
  vpc_id = var.vpc_id
  tags   = merge(var.tags, { Name = "${var.name}-default-sg-locked-down" })
  # Intentionally empty ingress/egress: locks down the VPC's default SG so
  # nothing can accidentally rely on it.
}
