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

variable "service_names" {
  description = "List of service names to create ECR repositories for"
  type        = list(string)
}

variable "image_tag_mutability" {
  description = "Tag mutability setting (MUTABLE for dev, IMMUTABLE for prod)"
  type        = string
  default     = "MUTABLE"

  validation {
    condition     = contains(["MUTABLE", "IMMUTABLE"], var.image_tag_mutability)
    error_message = "image_tag_mutability must be 'MUTABLE' or 'IMMUTABLE'."
  }
}

variable "force_delete" {
  description = "Allow deleting repositories with images (true for dev, false for prod)"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags to merge with default tags"
  type        = map(string)
  default     = {}
}
