locals {
  name_prefix = "${var.project}-${var.environment}"
}

# ------------------------------------------------------------------------------
# VPC
# ------------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, {
    Name      = "${local.name_prefix}-vpc"
    Component = "networking"
  })
}

# Restrict the default SG to deny all traffic (CIS AWS Benchmark 5.4).
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name      = "${local.name_prefix}-default-sg-RESTRICTED"
    Component = "security"
  })
}

# ------------------------------------------------------------------------------
# Public Subnets
# ------------------------------------------------------------------------------

resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name                                         = "${local.name_prefix}-public-${var.availability_zones[count.index]}"
    Component                                    = "networking"
    "kubernetes.io/cluster/${local.name_prefix}" = "shared"
    "kubernetes.io/role/elb"                     = "1"
    "karpenter.sh/discovery"                     = local.name_prefix
  })
}

# ------------------------------------------------------------------------------
# Internet Gateway
# ------------------------------------------------------------------------------

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name      = "${local.name_prefix}-igw"
    Component = "networking"
  })
}

# ------------------------------------------------------------------------------
# Route Table
# ------------------------------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(var.tags, {
    Name      = "${local.name_prefix}-public-rt"
    Component = "networking"
  })
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ------------------------------------------------------------------------------
# Security Groups
# ------------------------------------------------------------------------------

# --- EKS Cluster SG ---

resource "aws_security_group" "eks_cluster" {
  name        = "${local.name_prefix}-eks-cluster-sg"
  description = "Security group for EKS cluster control plane"
  vpc_id      = aws_vpc.main.id

  tags = merge(var.tags, {
    Name      = "${local.name_prefix}-eks-cluster-sg"
    Component = "security"
  })
}

resource "aws_security_group_rule" "eks_cluster_ingress_nodes" {
  description              = "Allow HTTPS from worker nodes to cluster API"
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_cluster.id
  source_security_group_id = aws_security_group.eks_node.id
}

resource "aws_security_group_rule" "eks_cluster_egress_all" {
  description       = "Allow all outbound traffic from cluster"
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.eks_cluster.id
  cidr_blocks       = ["0.0.0.0/0"]
}

# --- EKS Node SG ---

resource "aws_security_group" "eks_node" {
  name        = "${local.name_prefix}-eks-node-sg"
  description = "Security group for EKS worker nodes"
  vpc_id      = aws_vpc.main.id

  tags = merge(var.tags, {
    Name                     = "${local.name_prefix}-eks-node-sg"
    Component                = "security"
    "karpenter.sh/discovery" = local.name_prefix
  })
}

resource "aws_security_group_rule" "eks_node_ingress_cluster" {
  description              = "Allow all traffic from cluster control plane"
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.eks_node.id
  source_security_group_id = aws_security_group.eks_cluster.id
}

resource "aws_security_group_rule" "eks_node_ingress_self" {
  description              = "Allow inter-node communication"
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.eks_node.id
  source_security_group_id = aws_security_group.eks_node.id
}

resource "aws_security_group_rule" "eks_node_ingress_kubelet" {
  description              = "Allow kubelet API from cluster control plane"
  type                     = "ingress"
  from_port                = 10250
  to_port                  = 10250
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_node.id
  source_security_group_id = aws_security_group.eks_cluster.id
}

resource "aws_security_group_rule" "eks_node_ingress_nodeport" {
  description              = "Allow NodePort services from ALB"
  type                     = "ingress"
  from_port                = 30000
  to_port                  = 32767
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_node.id
  source_security_group_id = aws_security_group.alb.id
}

resource "aws_security_group_rule" "eks_node_ingress_alb_target_ip" {
  description              = "Allow ALB to reach pods directly on api-gateway container port (Ingress target-type=ip)"
  type                     = "ingress"
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_node.id
  source_security_group_id = aws_security_group.alb.id
}

resource "aws_security_group_rule" "eks_node_egress_all" {
  description       = "Allow all outbound traffic from nodes"
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.eks_node.id
  cidr_blocks       = ["0.0.0.0/0"]
}

# --- RDS SG ---

resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-rds-sg"
  description = "Security group for RDS MySQL - allows 3306 from EKS nodes only"
  vpc_id      = aws_vpc.main.id

  tags = merge(var.tags, {
    Name      = "${local.name_prefix}-rds-sg"
    Component = "security"
  })
}

resource "aws_security_group_rule" "rds_ingress_nodes" {
  description              = "Allow MySQL from EKS worker nodes only"
  type                     = "ingress"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds.id
  source_security_group_id = aws_security_group.eks_node.id
}

# --- ALB SG ---

resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "Security group for Application Load Balancer - public-facing"
  vpc_id      = aws_vpc.main.id

  tags = merge(var.tags, {
    Name      = "${local.name_prefix}-alb-sg"
    Component = "security"
  })
}

resource "aws_security_group_rule" "alb_ingress_http" {
  description       = "Allow HTTP from internet"
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  security_group_id = aws_security_group.alb.id
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "alb_ingress_https" {
  description       = "Allow HTTPS from internet"
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = aws_security_group.alb.id
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "alb_egress_nodeport" {
  description              = "Allow traffic to nodes on NodePort range"
  type                     = "egress"
  from_port                = 30000
  to_port                  = 32767
  protocol                 = "tcp"
  security_group_id        = aws_security_group.alb.id
  source_security_group_id = aws_security_group.eks_node.id
}

resource "aws_security_group_rule" "alb_egress_healthcheck" {
  description              = "Allow health checks to nodes on port 8080"
  type                     = "egress"
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  security_group_id        = aws_security_group.alb.id
  source_security_group_id = aws_security_group.eks_node.id
}
