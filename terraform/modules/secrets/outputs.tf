output "openai_secret_arn" {
  description = "Secrets Manager ARN for OpenAI API key"
  value       = aws_secretsmanager_secret.openai_api_key.arn
  sensitive   = true
}

output "grafana_admin_secret_arn" {
  description = "Secrets Manager ARN for Grafana admin credentials"
  value       = aws_secretsmanager_secret.grafana_admin.arn
  sensitive   = true
}
