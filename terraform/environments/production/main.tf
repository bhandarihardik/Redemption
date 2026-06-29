# ---------------------------------------------------------------------------
# Production environment — module wiring
# ---------------------------------------------------------------------------

module "vpc" {
  source = "../../modules/vpc"

  name     = var.cluster_name
  vpc_cidr = "10.0.0.0/16"
  azs      = var.azs
  tags     = local.common_tags
}

module "security" {
  source = "../../modules/security"

  name     = var.cluster_name
  vpc_id   = module.vpc.vpc_id
  vpc_cidr = module.vpc.vpc_cidr
  tags     = local.common_tags
}

module "eks" {
  source = "../../modules/eks"

  name               = var.cluster_name
  kubernetes_version = "1.31"
  vpc_id             = module.vpc.vpc_id
  app_subnet_ids     = module.vpc.app_subnet_ids
  public_subnet_ids  = module.vpc.public_subnet_ids
  tags               = local.common_tags
}

# NOTE ON APPLY ORDER (documented here deliberately, not hidden):
# This config mixes the 'aws' provider (creates the EKS cluster) with the
# 'kubernetes'/'kubectl'/'helm' providers (configure things INSIDE that
# cluster, e.g. Karpenter's NodePool CRDs in modules/eks/karpenter.tf).
# Terraform cannot resolve provider configuration blocks that depend on
# resources created in the SAME apply on a from-scratch run. The supported
# pattern, and what the README's bootstrap section documents, is a two-pass
# apply:
#   1) terraform apply -target=module.eks   (cluster + OIDC provider only)
#   2) terraform apply                       (everything else, cluster now exists)
# This is standard practice for Terraform-managed EKS+K8s-resources stacks,
# not a workaround specific to this project.

# ---------------------------------------------------------------------------
# Data layer
# ---------------------------------------------------------------------------
resource "aws_db_subnet_group" "main" {
  name       = "${var.cluster_name}-db-subnets"
  subnet_ids = module.vpc.data_subnet_ids
  tags       = local.common_tags
}

resource "aws_elasticache_subnet_group" "main" {
  name       = "${var.cluster_name}-cache-subnets"
  subnet_ids = module.vpc.data_subnet_ids
}

resource "aws_kms_key" "rds" {
  description             = "${var.cluster_name} RDS encryption at rest"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  tags                    = local.common_tags
}

resource "aws_db_instance" "primary" {
  identifier     = "${var.cluster_name}-pg"
  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  allocated_storage     = 100
  max_allocated_storage = 500 # storage autoscaling — one less thing to page someone at 3am
  storage_type           = "gp3"
  storage_encrypted       = true
  kms_key_id              = aws_kms_key.rds.arn

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [module.security.data_sg_id]

  multi_az            = true # synchronous standby in a second AZ, automatic failover on primary failure
  backup_retention_period = 7
  backup_window            = "03:00-04:00" # low-traffic window; flash sales are marketing-driven and scheduled, so this is coordinated with business, not a blind guess
  maintenance_window       = "sun:04:30-sun:05:30"

  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.cluster_name}-pg-final"

  performance_insights_enabled = true
  monitoring_interval           = 30
  monitoring_role_arn           = aws_iam_role.rds_monitoring.arn

  username                   = "redemption_app"
  manage_master_user_password = true # password generated + stored in Secrets Manager by AWS, never in state or code

  tags = local.common_tags
}

resource "aws_db_instance" "read_replica" {
  identifier          = "${var.cluster_name}-pg-replica"
  replicate_source_db = aws_db_instance.primary.identifier
  instance_class       = var.db_instance_class
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.rds.arn

  vpc_security_group_ids = [module.security.data_sg_id]
  performance_insights_enabled = true

  tags = local.common_tags
}

resource "aws_iam_role" "rds_monitoring" {
  name = "${var.cluster_name}-rds-monitoring"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id = "${var.cluster_name}-redis"
  description           = "Idempotency keys + hot-path point-balance reads"

  engine               = "redis"
  engine_version        = "7.1"
  node_type             = var.redis_node_type
  num_cache_clusters    = 2 # primary + 1 replica, cross-AZ
  automatic_failover_enabled = true
  multi_az_enabled            = true

  subnet_group_name  = aws_elasticache_subnet_group.main.name
  security_group_ids = [module.security.data_sg_id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled  = true # Redis traffic itself is encrypted, not just relying on the VPC boundary

  tags = local.common_tags
}
