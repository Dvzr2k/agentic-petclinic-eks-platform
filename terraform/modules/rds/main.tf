locals {
  name_prefix = "${var.project}-${var.environment}"
  db_name     = var.project
  db_username = var.project
}

# -----------------------------------------------------------------------------
# Database Credentials (random password + Secrets Manager)
# -----------------------------------------------------------------------------

resource "random_password" "master" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}|:?"
}

# [Checkov CKV_AWS_149 fix] Was relying on the default AWS-managed
# aws/secretsmanager key - that key's policy can't be scoped down further
# and every account principal with secretsmanager:* effectively gets
# decrypt access through it. A customer-managed key lets IAM/key-policy
# grant access to exactly this secret's decrypt path, and gives key usage
# its own CloudTrail trail independent of the Secrets Manager API logs.
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

resource "aws_kms_key" "rds_credentials" {
  description         = "Encryption for ${local.name_prefix} RDS credentials secret"
  enable_key_rotation = true

  # Explicit policy (Checkov CKV2_AWS_64) instead of relying on the
  # implicit default - grants root account admin, the same effective
  # access the default policy gives, just declared rather than assumed.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "EnableRootAccountAccess"
      Effect    = "Allow"
      Principal = { AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root" }
      Action    = "kms:*"
      Resource  = "*"
    }]
  })

  tags = merge(var.tags, {
    Name      = "${local.name_prefix}-rds-credentials-key"
    Component = "database"
  })
}

resource "aws_kms_alias" "rds_credentials" {
  name          = "alias/${local.name_prefix}-rds-credentials"
  target_key_id = aws_kms_key.rds_credentials.key_id
}

resource "aws_secretsmanager_secret" "rds_credentials" {
  name        = "${var.project}/${var.environment}/rds-credentials"
  description = "RDS MySQL credentials for ${local.name_prefix}"
  kms_key_id  = aws_kms_key.rds_credentials.arn

  tags = merge(var.tags, {
    Name      = "${local.name_prefix}-rds-credentials"
    Component = "database"
  })
}

resource "aws_secretsmanager_secret_version" "rds_credentials" {
  secret_id = aws_secretsmanager_secret.rds_credentials.id

  secret_string = jsonencode({
    username = local.db_username
    password = random_password.master.result
    engine   = "mysql"
    host     = aws_db_instance.main.address
    port     = aws_db_instance.main.port
    dbname   = local.db_name
  })
}

# -----------------------------------------------------------------------------
# DB Subnet Group
# -----------------------------------------------------------------------------

resource "aws_db_subnet_group" "main" {
  name       = "${local.name_prefix}-db-subnet-group"
  subnet_ids = var.subnet_ids

  tags = merge(var.tags, {
    Name      = "${local.name_prefix}-db-subnet-group"
    Component = "database"
  })
}

# -----------------------------------------------------------------------------
# DB Parameter Group (utf8mb4)
# -----------------------------------------------------------------------------

resource "aws_db_parameter_group" "main" {
  name   = "${local.name_prefix}-mysql-params"
  family = "mysql8.0"

  parameter {
    name  = "character_set_server"
    value = "utf8mb4"
  }

  parameter {
    name  = "collation_server"
    value = "utf8mb4_unicode_ci"
  }

  # [Checkov CKV2_AWS_69 fix] Without this, MySQL accepts unencrypted
  # connections alongside TLS ones - a client (or an app misconfig) can
  # silently fall back to plaintext. This rejects any connection that
  # doesn't negotiate TLS, at the database engine level rather than
  # relying on every client to opt in correctly.
  parameter {
    name  = "require_secure_transport"
    value = "1"
  }

  tags = merge(var.tags, {
    Name      = "${local.name_prefix}-mysql-params"
    Component = "database"
  })
}

# -----------------------------------------------------------------------------
# Enhanced Monitoring IAM Role
# -----------------------------------------------------------------------------

resource "aws_iam_role" "rds_enhanced_monitoring" {
  name = "${local.name_prefix}-rds-monitoring-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "monitoring.rds.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = merge(var.tags, {
    Name      = "${local.name_prefix}-rds-monitoring-role"
    Component = "database"
  })
}

resource "aws_iam_role_policy_attachment" "rds_enhanced_monitoring" {
  role       = aws_iam_role.rds_enhanced_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# -----------------------------------------------------------------------------
# RDS MySQL Instance
# -----------------------------------------------------------------------------

resource "aws_db_instance" "main" {
  identifier = "${local.name_prefix}-mysql"

  engine         = "mysql"
  engine_version = "8.0"
  instance_class = var.instance_class

  db_name  = local.db_name
  username = local.db_username
  password = random_password.master.result

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp2"
  storage_encrypted     = true

  multi_az               = var.multi_az
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [var.security_group_id]
  parameter_group_name   = aws_db_parameter_group.main.name
  publicly_accessible    = false

  backup_retention_period    = var.backup_retention_period
  backup_window              = "03:00-04:00"
  maintenance_window         = "sun:04:00-sun:05:00"
  auto_minor_version_upgrade = true
  # [Checkov CKV2_AWS_60 fix] Tags on the instance (Project/Environment/
  # ManagedBy) weren't propagating to automated snapshots, so a snapshot
  # created after this instance was destroyed would lose the metadata
  # needed to attribute it back to this project during cost/ownership review.
  copy_tags_to_snapshot = true

  # [Checkov CKV_AWS_129 fix] Without exporting these, error/slow-query
  # logs only exist on the instance's local storage for a few hours before
  # rotating out - CloudWatch Logs gives them a real retention window for
  # incident review or slow-query investigation after the fact.
  enabled_cloudwatch_logs_exports = ["error", "general", "slowquery"]

  # [Checkov CKV_AWS_118 fix] Standard CloudWatch metrics sample every 60s
  # at the hypervisor level; enhanced monitoring polls the OS itself every
  # 60s (CPU/memory/disk broken down by process), the resolution needed to
  # actually tell "is this slow because of the query or because the
  # instance is out of memory" during an incident.
  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.rds_enhanced_monitoring.arn

  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${local.name_prefix}-mysql-final"
  deletion_protection       = var.deletion_protection

  tags = merge(var.tags, {
    Name      = "${local.name_prefix}-mysql"
    Component = "database"
  })
}
