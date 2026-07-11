# -----------------------------------------------------------------------------
# DNS & ACM (PETPLAT-28, PETPLAT-32)
# -----------------------------------------------------------------------------

module "dns" {
  source = "../../modules/dns"

  domain_name = var.domain_name
  tags = {
    Name = "petclinic-${var.environment}-cert"
  }
}

# -----------------------------------------------------------------------------
# Route 53 alias A record → ALB (PETPLAT-31)
#
# The ALB is provisioned by the LB controller when k8s/base/ingress/ingress.yaml
# is applied. Run terraform apply a second time after the ALB exists:
#   terraform apply -var="create_alb_dns_record=true"
# -----------------------------------------------------------------------------

resource "aws_route53_record" "petclinic_dev" {
  count = var.alb_dns_name != "" ? 1 : 0

  zone_id = module.dns.zone_id
  name    = "petclinic-dev.${var.domain_name}"
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_hosted_zone_id
    evaluate_target_health = true
  }
}

# -----------------------------------------------------------------------------

module "vpc" {
  source = "../../modules/vpc"

  project             = var.project
  environment         = var.environment
  vpc_cidr            = "10.0.0.0/16"
  public_subnet_cidrs = ["10.0.1.0/24", "10.0.2.0/24"]
  availability_zones  = ["eu-central-1a", "eu-central-1b"]
}

module "eks" {
  source = "../../modules/eks"

  project         = var.project
  environment     = var.environment
  cluster_version = "1.34"
  subnet_ids      = module.vpc.public_subnet_ids
  cluster_sg_id   = module.vpc.eks_cluster_sg_id
  node_sg_id      = module.vpc.eks_node_sg_id

  node_instance_types = ["t4g.small"]
  node_ami_type       = "AL2023_ARM_64_STANDARD"
  node_min_size       = 8
  node_max_size       = 8
  node_desired_size   = 8
  node_disk_size      = 20
}

module "ecr" {
  source = "../../modules/ecr"

  project     = var.project
  environment = var.environment

  service_names = [
    "config-server",
    "discovery-server",
    "api-gateway",
    "customers-service",
    "visits-service",
    "vets-service",
    "genai-service",
    "admin-server",
  ]

  image_tag_mutability = "MUTABLE"
}

module "rds" {
  source = "../../modules/rds"

  project           = var.project
  environment       = var.environment
  subnet_ids        = module.vpc.public_subnet_ids
  security_group_id = module.vpc.rds_sg_id

  instance_class          = "db.t4g.micro"
  allocated_storage       = 20
  max_allocated_storage   = 20
  multi_az                = false
  backup_retention_period = 7
  skip_final_snapshot     = true
  deletion_protection     = false
}

# -----------------------------------------------------------------------------
# Secrets Manager (PETPLAT-33)
# -----------------------------------------------------------------------------

module "secrets" {
  source = "../../modules/secrets"

  project        = var.project
  environment    = var.environment
  openai_api_key = var.openai_api_key
}

# -----------------------------------------------------------------------------
# GitHub Actions OIDC (PETPLAT-52) — account-wide CI identity, not per-env.
# Applied once from dev since that's the only environment actually deployed;
# the resulting role can push to both petclinic-dev/* and petclinic-prod/*
# ECR repos (see the module's resource ARN pattern).
# -----------------------------------------------------------------------------

module "github_oidc" {
  source = "../../modules/github-oidc"

  project               = var.project
  app_repo_github_owner = "Dvzr2k" # derived from `git -C ../spring-petclinic-microservices remote get-url origin`, not a placeholder
  tags = {
    Name = "petclinic-github-actions"
  }
}

# -----------------------------------------------------------------------------
# Karpenter (PETPLAT-73) — IAM/SQS/EventBridge prerequisites for node
# autoscaling. The Karpenter controller itself (Helm) and NodePool/EC2NodeClass
# CRDs are applied via kubectl, not Terraform — see k8s/base/karpenter/.
# -----------------------------------------------------------------------------

module "karpenter" {
  source = "../../modules/karpenter"

  project           = var.project
  environment       = var.environment
  cluster_name      = module.eks.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  node_role_arn     = module.eks.node_role_arn

  tags = {
    Name = "petclinic-dev-karpenter"
  }
}

# -----------------------------------------------------------------------------
# AWS Budget (PETPLAT-75) — $100/month threshold, alerts at 50/80/100% of
# ACTUAL spend (not forecasted) so notifications fire on real cost, not a
# projection.
# -----------------------------------------------------------------------------

resource "aws_budgets_budget" "monthly" {
  name         = "petclinic-${var.environment}-monthly-budget"
  budget_type  = "COST"
  limit_amount = "100"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = [format("user:Environment$%s", var.environment)]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }
}
