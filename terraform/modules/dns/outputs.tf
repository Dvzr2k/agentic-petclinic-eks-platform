output "zone_id" {
  description = "Route 53 hosted zone ID"
  value       = data.aws_route53_zone.main.zone_id
}

output "name_servers" {
  description = "NS records for the hosted zone"
  value       = data.aws_route53_zone.main.name_servers
}

output "certificate_arn" {
  description = "Validated ACM wildcard certificate ARN"
  value       = aws_acm_certificate_validation.main.certificate_arn
}
