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

variable "tags" {
  description = "Additional tags to merge with default tags"
  type        = map(string)
  default     = {}
}
