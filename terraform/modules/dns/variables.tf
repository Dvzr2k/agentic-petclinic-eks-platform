variable "domain_name" {
  description = "Domain name for the Route 53 hosted zone and ACM wildcard certificate"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9\\-\\.]+\\.[a-z]{2,}$", var.domain_name))
    error_message = "domain_name must be a valid domain (e.g. example.com)."
  }
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
