# ---------------------------------------------------------------------------
# EKS Cluster — control plane + baseline managed node group + IRSA roles
#
# Design rationale (see design doc section A/B for the full trade-off table):
#
#   - Control plane logging: all 5 log types enabled. This is "free"
#     observability that's easy to forget and expensive to need later when
#     debugging a postmortem with no audit trail.
#
#   - Two-lane compute model:
#       1) "baseline" managed node group (this file)    -> on-demand, fixed
#          floor, always covers steady-state traffic. Never touched by
#          Karpenter. This is what's still standing if Karpenter or spot
#          capacity has a bad day.
#       2) Karpenter NodePools (karpenter.tf)            -> the burst lane
#          for the 10x flash-sale spike, spot-heavy for cost, provisions
#          new nodes in under a minute against pending pod shapes.
#     Why not just one big Cluster-Autoscaler-managed ASG? CA scales
#     existing ASGs of a FIXED instance type/size and reacts to scheduling
#     failures relatively slowly. Karpenter reasons directly from pending
#     pod resource requests to the cheapest/fastest-available instance
#     shape, which is materially faster for sudden spikes and cheaper for
#     steady state. Using both gives us "guaranteed floor" + "fast, cheap
#     burst" instead of picking one.
#
#   - IRSA (IAM Roles for Service Accounts) everywhere, not node-level IAM
#     roles. This is the EKS expression of least privilege: the Karpenter
#     controller, the AWS Load Balancer Controller, External Secrets, and
#     the application pods themselves each get their own narrowly-scoped
#     IAM role bound to a Kubernetes ServiceAccount, instead of all pods on
#     a node inheriting one fat node IAM role.
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ---------------------------------------------------------------------------
# Control plane
# ---------------------------------------------------------------------------
resource "aws_security_group" "cluster" {
  name        = "${var.name}-cluster-sg"
  description = "EKS control plane security group"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-cluster-sg" })
}

resource "aws_iam_role" "cluster" {
  name = "${var.name}-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.cluster.name
}

resource "aws_eks_cluster" "main" {
  name     = var.name
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids              = concat(var.app_subnet_ids, var.public_subnet_ids)
    security_group_ids      = [aws_security_group.cluster.id]
    endpoint_private_access = true
    # Public endpoint stays on but should be restricted to office/VPN CIDRs
    # in production via endpoint_public_access_cidrs — left open here only
    # for assessment portability; tighten before real production use.
    endpoint_public_access  = true
  }

  # All 5 log types — cheap insurance, invaluable during a postmortem.
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  encryption_config {
    provider {
      key_arn = aws_kms_key.eks_secrets.arn
    }
    resources = ["secrets"]
  }

  tags = var.tags

  depends_on = [aws_iam_role_policy_attachment.cluster_policy]
}

# Envelope-encrypt Kubernetes Secrets at rest with a customer-managed key,
# not just the default AWS-managed key — gives us key rotation control and
# an auditable trail of who can decrypt cluster secrets.
resource "aws_kms_key" "eks_secrets" {
  description             = "${var.name} EKS secrets encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  tags                    = var.tags
}

resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/${var.name}/cluster"
  retention_in_days = 90
  tags              = var.tags
}

# ---------------------------------------------------------------------------
# OIDC provider — required for IRSA
# ---------------------------------------------------------------------------
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  tags            = var.tags
}

# ---------------------------------------------------------------------------
# Baseline managed node group — the guaranteed floor (lane 1 of 2)
# ---------------------------------------------------------------------------
resource "aws_iam_role" "baseline_nodes" {
  name = "${var.name}-baseline-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "baseline_worker" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore", # session manager access, no SSH keys/bastion needed
  ])
  policy_arn = each.value
  role       = aws_iam_role.baseline_nodes.name
}

resource "aws_eks_node_group" "baseline" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.name}-baseline"
  node_role_arn   = aws_iam_role.baseline_nodes.arn
  subnet_ids      = var.app_subnet_ids

  # Deliberately spread 1:1 across AZs by using all 3 app subnets with
  # min_size == az_count, so the scheduler-level topology spread constraint
  # in the app manifests has guaranteed homes in every AZ.
  scaling_config {
    min_size     = var.baseline_min_size
    max_size     = var.baseline_max_size
    desired_size = var.baseline_min_size
  }

  instance_types = var.baseline_instance_types
  capacity_type  = "ON_DEMAND" # baseline lane is never spot — this is the floor that must not disappear

  update_config {
    max_unavailable_percentage = 33 # never take down more than 1 AZ-worth at once during node rotation
  }

  labels = {
    "workload-tier" = "baseline"
  }

  tags = var.tags

  depends_on = [aws_iam_role_policy_attachment.baseline_worker]

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size] # let Karpenter/HPA-driven node count drift without Terraform fighting it
  }
}

# ---------------------------------------------------------------------------
# IRSA role factory — used by karpenter.tf, addons.tf and the app's own
# ServiceAccount for scoped AWS access (e.g. reading Secrets Manager).
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "irsa_assume" {
  for_each = toset(["karpenter", "lb-controller", "external-secrets", "external-dns", "app"])

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:${local.irsa_namespaces[each.key]}:${local.irsa_sa_names[each.key]}"]
    }
  }
}

locals {
  irsa_namespaces = {
    karpenter         = "karpenter"
    "lb-controller"   = "kube-system"
    "external-secrets" = "external-secrets"
    "external-dns"    = "external-dns"
    app               = "redemption"
  }
  irsa_sa_names = {
    karpenter         = "karpenter"
    "lb-controller"   = "aws-load-balancer-controller"
    "external-secrets" = "external-secrets"
    "external-dns"    = "external-dns"
    app               = "the-redemption"
  }
}

resource "aws_iam_role" "irsa" {
  for_each           = data.aws_iam_policy_document.irsa_assume
  name               = "${var.name}-irsa-${each.key}"
  assume_role_policy = each.value.json
  tags               = var.tags
}
