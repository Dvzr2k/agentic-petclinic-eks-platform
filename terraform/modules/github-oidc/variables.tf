variable "project" {
  description = "Project name, used for resource naming and to scope the ECR resource ARN pattern (petclinic-*)"
  type        = string
}

variable "app_repo_github_owner" {
  description = "GitHub username/org that owns the application repo fork — derived from `git remote get-url origin` in that repo, never hardcoded, since the OIDC trust policy subject must reference the actual fork"
  type        = string
}

variable "app_repo_name" {
  description = "Application repo name (the repo whose build-push.yml assumes this role)"
  type        = string
  default     = "spring-petclinic-microservices"
}

variable "tags" {
  description = "Common tags applied to all resources in this module"
  type        = map(string)
  default     = {}
}
