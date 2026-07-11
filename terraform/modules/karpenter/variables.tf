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

variable "cluster_name" {
  description = "Name of the EKS cluster Karpenter provisions nodes for"
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the EKS cluster's OIDC provider (for the Karpenter controller's IRSA trust policy)"
  type        = string
}

variable "oidc_provider_url" {
  description = "URL of the EKS cluster's OIDC provider, without the https:// prefix (for the IRSA trust policy condition keys)"
  type        = string
}

variable "node_role_arn" {
  description = "ARN of the existing EKS node IAM role, reused for the Karpenter-launched node instance profile"
  type        = string
}

variable "tags" {
  description = "Additional tags to merge with default tags"
  type        = map(string)
  default     = {}
}
