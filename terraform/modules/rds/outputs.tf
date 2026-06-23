output "endpoint" {
  description = "RDS endpoint hostname"
  value       = aws_db_instance.main.address
}

output "port" {
  description = "RDS port"
  value       = aws_db_instance.main.port
}

output "db_instance_id" {
  description = "RDS instance identifier"
  value       = aws_db_instance.main.id
}

output "secret_arn" {
  description = "Secrets Manager ARN for RDS credentials"
  value       = aws_secretsmanager_secret.rds_credentials.arn
}

output "db_name" {
  description = "Name of the database"
  value       = local.db_name
}

output "connection_string" {
  description = "JDBC connection string for the database"
  value       = "jdbc:mysql://${aws_db_instance.main.address}:${aws_db_instance.main.port}/${local.db_name}"
  sensitive   = true
}
