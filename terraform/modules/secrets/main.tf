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

# -----------------------------------------------------------------------------
# Grafana admin credentials (fixes CRIT-001 from security-auditor: the admin
# password was previously hardcoded directly in k8s/base/observability/
# grafana.yaml and committed to git). Generated randomly here instead, flows
# through Secrets Manager -> ExternalSecret -> K8s Secret, same pattern as
# the OpenAI key and RDS credentials above.
# -----------------------------------------------------------------------------

resource "random_password" "grafana_admin" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}|:?"
}

resource "aws_secretsmanager_secret" "grafana_admin" {
  name        = "${var.project}/${var.environment}/grafana-admin"
  description = "Grafana admin credentials (${var.project}-${var.environment})"

  tags = merge(var.tags, {
    Name      = "${var.project}-${var.environment}-grafana-admin"
    Component = "secrets"
  })
}

resource "aws_secretsmanager_secret_version" "grafana_admin" {
  secret_id = aws_secretsmanager_secret.grafana_admin.id
  secret_string = jsonencode({
    admin-user     = "admin"
    admin-password = random_password.grafana_admin.result
  })
}

# -----------------------------------------------------------------------------
# Alertmanager SMTP credentials (fixes MED-002 from security-auditor: SMTP
# host/username/password were hardcoded directly in k8s/base/observability/
# alertmanager.yaml — the one secret in the repo that bypassed the Secrets
# Manager -> ExternalSecret -> K8s Secret pattern used everywhere else).
# Still placeholder values by default — see variables.tf.
# -----------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "alertmanager_smtp" {
  name        = "${var.project}/${var.environment}/alertmanager-smtp"
  description = "Alertmanager SMTP credentials (${var.project}-${var.environment})"

  tags = merge(var.tags, {
    Name      = "${var.project}-${var.environment}-alertmanager-smtp"
    Component = "secrets"
  })
}

resource "aws_secretsmanager_secret_version" "alertmanager_smtp" {
  secret_id = aws_secretsmanager_secret.alertmanager_smtp.id
  secret_string = jsonencode({
    smtp-host     = var.smtp_host
    smtp-username = var.smtp_username
    smtp-password = var.smtp_password
  })
}
