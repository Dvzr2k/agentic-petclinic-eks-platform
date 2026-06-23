# --- VPC outputs ---

output "vpc_id" {
  description = "ID of the prod VPC"
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "IDs of the prod public subnets"
  value       = module.vpc.public_subnet_ids
}

output "eks_cluster_sg_id" {
  description = "ID of the EKS cluster security group"
  value       = module.vpc.eks_cluster_sg_id
}

output "eks_node_sg_id" {
  description = "ID of the EKS node security group"
  value       = module.vpc.eks_node_sg_id
}

output "rds_sg_id" {
  description = "ID of the RDS security group"
  value       = module.vpc.rds_sg_id
}

output "alb_sg_id" {
  description = "ID of the ALB security group"
  value       = module.vpc.alb_sg_id
}

# --- EKS outputs ---

output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Endpoint URL of the EKS cluster API server"
  value       = module.eks.cluster_endpoint
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC provider for IRSA"
  value       = module.eks.oidc_provider_arn
}

output "node_group_name" {
  description = "Name of the EKS managed node group"
  value       = module.eks.node_group_name
}

output "node_role_arn" {
  description = "ARN of the EKS node IAM role"
  value       = module.eks.node_role_arn
}

output "kubeconfig_command" {
  description = "Command to configure kubectl access"
  value       = module.eks.kubeconfig_command
}

# --- ECR outputs ---

output "ecr_repository_urls" {
  description = "Map of service name to ECR repository URL"
  value       = module.ecr.repository_urls
}

# --- RDS outputs ---

output "rds_endpoint" {
  description = "RDS MySQL endpoint hostname"
  value       = module.rds.endpoint
}

output "rds_connection_string" {
  description = "JDBC connection string for the database"
  value       = module.rds.connection_string
  sensitive   = true
}

output "rds_secret_arn" {
  description = "Secrets Manager ARN for RDS credentials"
  value       = module.rds.secret_arn
}
