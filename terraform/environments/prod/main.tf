# -----------------------------------------------------------------------------
# DNS & ACM (PETPLAT-28, PETPLAT-32 — prod)
# -----------------------------------------------------------------------------

module "dns" {
  source = "../../modules/dns"

  domain_name = var.domain_name
  tags = {
    Name = "petclinic-${var.environment}-cert"
  }
}

# -----------------------------------------------------------------------------
# Route 53 alias A record → ALB (PETPLAT-31 — prod)
#
# Apply after k8s Ingress creates the ALB:
#   terraform apply -var="create_alb_dns_record=true"
# -----------------------------------------------------------------------------

data "aws_lb" "petclinic_prod" {
  count = var.create_alb_dns_record ? 1 : 0

  tags = {
    "kubernetes.io/cluster/petclinic-prod" = "owned"
    "Ingress"                               = "petclinic-ingress"
  }
}

resource "aws_route53_record" "petclinic_prod" {
  count = var.create_alb_dns_record ? 1 : 0

  zone_id = module.dns.zone_id
  name    = "petclinic.${var.domain_name}"
  type    = "A"

  alias {
    name                   = data.aws_lb.petclinic_prod[0].dns_name
    zone_id                = data.aws_lb.petclinic_prod[0].zone_id
    evaluate_target_health = true
  }
}

# -----------------------------------------------------------------------------

module "vpc" {
  source = "../../modules/vpc"

  project             = var.project
  environment         = var.environment
  vpc_cidr            = "10.1.0.0/16"
  public_subnet_cidrs = ["10.1.1.0/24", "10.1.2.0/24"]
  availability_zones  = ["eu-central-1a", "eu-central-1b"]
}

module "eks" {
  source = "../../modules/eks"

  project         = var.project
  environment     = var.environment
  cluster_version = "1.32"
  subnet_ids      = module.vpc.public_subnet_ids
  cluster_sg_id   = module.vpc.eks_cluster_sg_id
  node_sg_id      = module.vpc.eks_node_sg_id

  node_instance_types = ["t4g.small"]
  node_ami_type       = "AL2_ARM_64"
  node_min_size       = 2
  node_max_size       = 4
  node_desired_size   = 2
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

  image_tag_mutability = "IMMUTABLE"
  force_delete         = false
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
  backup_retention_period = 30
  skip_final_snapshot     = false
  deletion_protection     = false
}
