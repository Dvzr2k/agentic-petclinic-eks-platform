variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "eu-central-1"
}

variable "environment" {
  description = "Environment name (dev or prod)"
  type        = string
  default     = "dev"

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

variable "alb_dns_name" {
  description = "DNS name of the ALB created by the LB controller (from kubectl get ingress)"
  type        = string
  default     = ""
}

variable "alb_hosted_zone_id" {
  description = "Canonical hosted zone ID of the ALB (from aws elbv2 describe-load-balancers)"
  type        = string
  default     = ""
}

variable "openai_api_key" {
  description = "OpenAI API key for the GenAI service. Never set in terraform.tfvars — supply via TF_VAR_openai_api_key env var or -var at apply time."
  type        = string
  sensitive   = true
}
