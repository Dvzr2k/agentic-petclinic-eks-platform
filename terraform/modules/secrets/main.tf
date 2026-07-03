# Secrets module — implemented in PETPLAT-33 (E-7 Secrets Management).
# Manages non-RDS application secrets in AWS Secrets Manager.
# RDS credentials are owned by the rds module (PETPLAT-23) — not duplicated here.

resource "aws_secretsmanager_secret" "openai_api_key" {
  name        = "${var.project}/${var.environment}/openai-api-key"
  description = "OpenAI API key for the GenAI service (${var.project}-${var.environment})"

  tags = merge(var.tags, {
    Name      = "${var.project}-${var.environment}-openai-api-key"
    Component = "secrets"
  })
}

resource "aws_secretsmanager_secret_version" "openai_api_key" {
  secret_id     = aws_secretsmanager_secret.openai_api_key.id
  secret_string = var.openai_api_key
}
