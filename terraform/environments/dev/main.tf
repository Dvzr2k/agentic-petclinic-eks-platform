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
