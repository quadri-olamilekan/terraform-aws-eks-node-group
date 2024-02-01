output "eks-oidc_arn" {
  value = aws_iam_role.oidc.arn
}

output "oidc-url" {
  value = aws_iam_openid_connect_provider.eks.url
}

output "oidc-arn" {
  value = aws_iam_openid_connect_provider.eks.arn
}

output "eks_cluster_autoscaler_arn" {
  value = aws_iam_role.eks_cluster_autoscaler.arn
}