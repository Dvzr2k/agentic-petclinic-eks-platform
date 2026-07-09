output "oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider (pre-existing, looked up not created — see main.tf)"
  value       = data.aws_iam_openid_connect_provider.github_actions.arn
}

output "role_arn" {
  description = "ARN of the IAM role GitHub Actions assumes — set as the AWS_ROLE_ARN GitHub secret in the application repo"
  value       = aws_iam_role.github_actions.arn
}
