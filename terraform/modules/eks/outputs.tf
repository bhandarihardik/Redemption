output "cluster_name" {
  value = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.main.endpoint
}

output "cluster_ca" {
  value = aws_eks_cluster.main.certificate_authority[0].data
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.eks.arn
}

output "irsa_role_arns" {
  description = "Map of logical name -> IAM role ARN, for binding to Kubernetes ServiceAccount annotations"
  value       = { for k, v in aws_iam_role.irsa : k => v.arn }
}

output "baseline_node_role_arn" {
  value = aws_iam_role.baseline_nodes.arn
}
