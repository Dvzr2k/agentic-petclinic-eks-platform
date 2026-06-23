output "repository_urls" {
  description = "Map of service_name to ECR repository URL"
  value       = { for name, repo in aws_ecr_repository.service : name => repo.repository_url }
}

output "repository_arns" {
  description = "Map of service_name to ECR repository ARN"
  value       = { for name, repo in aws_ecr_repository.service : name => repo.arn }
}
