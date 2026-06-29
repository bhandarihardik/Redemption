output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "rds_primary_endpoint" {
  value = aws_db_instance.primary.endpoint
}

output "rds_replica_endpoint" {
  value = aws_db_instance.read_replica.endpoint
}

output "redis_primary_endpoint" {
  value = aws_elasticache_replication_group.redis.primary_endpoint_address
}

output "waf_web_acl_arn" {
  value = aws_wafv2_web_acl.main.arn
}

output "kubectl_config_command" {
  description = "Run this after apply to configure local kubectl access"
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}"
}
