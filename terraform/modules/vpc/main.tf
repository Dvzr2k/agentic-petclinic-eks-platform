locals {
  name_prefix = "${var.project}-${var.environment}"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

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

# -----------------------------------------------------------------------------
# VPC Flow Logs
#
# [Checkov CKV2_AWS_11 fix] Without this, there's no record of what
# traffic actually crossed the VPC after the fact - relevant here
# specifically because there's no NAT Gateway (ADR-0001, SGs are the
# perimeter instead), so flow logs are the one place to see what a pod's
# egress traffic to the internet actually looked like if something needs
# investigating after the fact.
# -----------------------------------------------------------------------------

resource "aws_kms_key" "vpc_flow_log" {
  description         = "Encryption for ${local.name_prefix} VPC flow log group"
  enable_key_rotation = true

  # Explicit policy (Checkov CKV2_AWS_64) instead of relying on the
  # implicit default - grants the account root full admin, same effective
  # access the default policy gives, just stated rather than assumed. Also
  # grants the region's logs service permission to use the key for
  # encrypting log data, which CloudWatch Logs requires for a KMS-backed
  # log group.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccountAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowCloudWatchLogs"
        Effect    = "Allow"
        Principal = { Service = "logs.${data.aws_region.current.name}.amazonaws.com" }
        Action    = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
        Resource  = "*"
      },
    ]
  })

  tags = merge(var.tags, {
    Name      = "${local.name_prefix}-vpc-flow-log-key"
    Component = "networking"
  })
}

resource "aws_cloudwatch_log_group" "vpc_flow_log" {
  name = "/aws/vpc/${local.name_prefix}-flow-logs"
  # [Checkov CKV_AWS_338 fix] Was 30 days - bumped to a full year so an
  # investigation months after an incident still has the traffic record,
  # not just the last month.
  retention_in_days = 365
  kms_key_id        = aws_kms_key.vpc_flow_log.arn

  tags = merge(var.tags, {
    Name      = "${local.name_prefix}-vpc-flow-logs"
    Component = "networking"
  })
}

resource "aws_iam_role" "vpc_flow_log" {
  name = "${local.name_prefix}-vpc-flow-log-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "vpc-flow-logs.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = merge(var.tags, {
    Name      = "${local.name_prefix}-vpc-flow-log-role"
    Component = "networking"
  })
}

resource "aws_iam_role_policy" "vpc_flow_log" {
  name = "${local.name_prefix}-vpc-flow-log-policy"
  role = aws_iam_role.vpc_flow_log.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
      ]
      Resource = "${aws_cloudwatch_log_group.vpc_flow_log.arn}:*"
    }]
  })
}

resource "aws_flow_log" "main" {
  vpc_id                   = aws_vpc.main.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.vpc_flow_log.arn
  iam_role_arn             = aws_iam_role.vpc_flow_log.arn
  max_aggregation_interval = 600

  tags = merge(var.tags, {
    Name      = "${local.name_prefix}-vpc-flow-log"
    Component = "networking"
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
