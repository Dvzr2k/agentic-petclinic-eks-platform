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

resource "aws_secretsmanager_secret" "rds_credentials" {
  name        = "${var.project}/${var.environment}/rds-credentials"
  description = "RDS MySQL credentials for ${local.name_prefix}"

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

  tags = merge(var.tags, {
    Name      = "${local.name_prefix}-mysql-params"
    Component = "database"
  })
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

  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${local.name_prefix}-mysql-final"
  deletion_protection       = var.deletion_protection

  tags = merge(var.tags, {
    Name      = "${local.name_prefix}-mysql"
    Component = "database"
  })
}
