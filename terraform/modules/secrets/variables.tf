variable "project" {
  description = "Project name used in resource naming"
  type        = string
  default     = "petclinic"
}

variable "environment" {
  description = "Environment name (dev or prod)"
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "Environment must be 'dev' or 'prod'."
  }
}

variable "openai_api_key" {
  description = "OpenAI API key value for the GenAI service. Never hardcode — supply via TF_VAR_openai_api_key or -var at apply time."
  type        = string
  sensitive   = true
}

# [MED-002 fix] Alertmanager SMTP — still non-functional placeholders by
# default (no real mail server configured yet), same status quo as before.
# The fix isn't "make email work," it's "make the eventual real value flow
# through Secrets Manager instead of being hand-edited into a committed
# YAML file." Supply real values via TF_VAR_smtp_* or -var at apply time
# once real SMTP credentials exist.
variable "smtp_host" {
  description = "SMTP server host:port for Alertmanager email notifications"
  type        = string
  default     = "smtp.placeholder-not-configured.example:587"
}

variable "smtp_username" {
  description = "SMTP auth username for Alertmanager email notifications"
  type        = string
  default     = "placeholder@example.com"
}

variable "smtp_password" {
  description = "SMTP auth password for Alertmanager email notifications. Never hardcode — supply via TF_VAR_smtp_password or -var at apply time."
  type        = string
  sensitive   = true
  default     = "placeholder-not-a-real-password"
}

variable "tags" {
  description = "Additional tags to merge with default tags"
  type        = map(string)
  default     = {}
}
