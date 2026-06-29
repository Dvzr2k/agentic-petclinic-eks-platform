variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "eu-central-1"
}

variable "environment" {
  description = "Environment name (dev or prod)"
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "Environment must be 'dev' or 'prod'."
  }
}

variable "project" {
  description = "Project name used in resource naming and tagging"
  type        = string
  default     = "petclinic"
}

variable "domain_name" {
  description = "Domain name for Route 53 hosted zone and ACM certificate"
  type        = string
  default     = "app-valdezr.link"
}

variable "create_alb_dns_record" {
  description = "Set to true after the Ingress creates the ALB to wire the Route 53 alias record"
  type        = bool
  default     = false
}
