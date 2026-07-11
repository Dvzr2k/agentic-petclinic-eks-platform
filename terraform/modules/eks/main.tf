locals {
  name_prefix       = "${var.project}-${var.environment}"
  cluster_name      = "${var.project}-${var.environment}"
  oidc_provider_url = replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

# -----------------------------------------------------------------------------
# Cluster IAM Role
# -----------------------------------------------------------------------------

resource "aws_iam_role" "cluster" {
  name = "${local.name_prefix}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = merge(var.tags, {
    Name      = "${local.name_prefix}-eks-cluster-role"
    Component = "compute"
  })
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.cluster.name
}

# AmazonEKSClusterPolicy doesn't grant KMS access - the cluster role needs
# this explicitly to use aws_kms_key.eks_secrets for envelope encryption.
resource "aws_iam_role_policy" "cluster_kms" {
  name = "${local.name_prefix}-eks-cluster-kms-policy"
  role = aws_iam_role.cluster.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "kms:Decrypt",
        "kms:DescribeKey",
        "kms:CreateGrant",
        "kms:Encrypt",
      ]
      Resource = aws_kms_key.eks_secrets.arn
    }]
  })
}

# -----------------------------------------------------------------------------
# EKS Cluster
# -----------------------------------------------------------------------------

resource "aws_eks_cluster" "main" {
  name     = local.cluster_name
  version  = var.cluster_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids             = var.subnet_ids
    security_group_ids     = [var.cluster_sg_id]
    endpoint_public_access = true
    # [Bug found while verifying MED-004] Must be true, not false. With
    # only the public endpoint enabled and public_access_cidrs restricted
    # to an admin IP, nodes themselves (which reach the API server via the
    # public endpoint when private access is off) get locked out of their
    # own control plane — new nodes can never register, and Karpenter can
    # never successfully add capacity. Enabling private access gives nodes
    # (already inside the VPC) a path that isn't subject to the public
    # CIDR restriction, while humans still use the restricted public path.
    endpoint_private_access = true
    # [HIGH-002 fix] Was unset, defaulting to 0.0.0.0/0 (reachable from
    # the whole internet). IAM auth is still required to do anything once
    # connected, but this removes that extra network-layer barrier.
    public_access_cidrs = var.public_access_cidrs
  }

  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"
  }

  # [Checkov CKV_AWS_37 fix] Was missing controllerManager/scheduler -
  # those two are what show scheduling decisions and control-loop errors,
  # the other three alone only cover API access and auth.
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # [Checkov CKV_AWS_58 fix] EKS stores Kubernetes Secret objects in etcd;
  # without this they're only encrypted by EBS-level encryption on the
  # control plane's own storage (which we don't manage or see) - this adds
  # application-layer envelope encryption on top, scoped to just the
  # "secrets" resource type.
  encryption_config {
    resources = ["secrets"]
    provider {
      key_arn = aws_kms_key.eks_secrets.arn
    }
  }

  tags = merge(var.tags, {
    Name      = local.cluster_name
    Component = "compute"
  })

  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy,
  ]
}

resource "aws_kms_key" "eks_secrets" {
  description         = "Envelope encryption for ${local.cluster_name} Kubernetes Secrets"
  enable_key_rotation = true

  # Explicit policy (Checkov CKV2_AWS_64) instead of relying on the
  # implicit default - grants root account admin (same as the default
  # would), plus the cluster role's own decrypt/grant access declared
  # here directly rather than only through the separate IAM policy.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccountAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowEKSClusterRole"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.cluster.arn }
        Action    = ["kms:Decrypt", "kms:DescribeKey", "kms:CreateGrant", "kms:Encrypt"]
        Resource  = "*"
      },
    ]
  })

  tags = merge(var.tags, {
    Name      = "${local.name_prefix}-eks-secrets-key"
    Component = "compute"
  })
}

resource "aws_kms_alias" "eks_secrets" {
  name          = "alias/${local.name_prefix}-eks-secrets"
  target_key_id = aws_kms_key.eks_secrets.key_id
}

# -----------------------------------------------------------------------------
# OIDC Provider (for IRSA)
# -----------------------------------------------------------------------------

data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer

  tags = merge(var.tags, {
    Name      = "${local.name_prefix}-eks-oidc"
    Component = "compute"
  })
}

# -----------------------------------------------------------------------------
# EKS Access Entry (kubectl access for deploying principal)
# -----------------------------------------------------------------------------

resource "aws_eks_access_entry" "admin" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = data.aws_caller_identity.current.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_eks_access_entry.admin.principal_arn
  policy_arn    = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

# -----------------------------------------------------------------------------
# Node IAM Role
# -----------------------------------------------------------------------------

resource "aws_iam_role" "node" {
  name = "${local.name_prefix}-eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = merge(var.tags, {
    Name      = "${local.name_prefix}-eks-node-role"
    Component = "compute"
  })
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "node_ecr" {
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.node.name
}

# [Checkov CKV_AWS_136 follow-up] ECR repos now encrypt image layers with a
# customer-managed KMS key (ecr module) instead of the default AWS-owned
# key - AmazonEC2ContainerRegistryReadOnly doesn't grant KMS access, so
# without this every image pull would fail once applied. Same
# ViaService-scoped pattern as the ESO policy above: only works for a KMS
# call made *by* ECR during an image pull, not a direct kms:Decrypt call.
resource "aws_iam_role_policy" "node_ecr_kms" {
  name = "${local.name_prefix}-node-ecr-kms-policy"
  role = aws_iam_role.node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "kms:Decrypt"
      Resource = "*"
      Condition = {
        StringEquals = {
          "kms:ViaService" = "ecr.${data.aws_region.current.name}.amazonaws.com"
        }
      }
    }]
  })
}

# -----------------------------------------------------------------------------
# Launch Template (attaches custom node SG + EKS-managed cluster SG)
# -----------------------------------------------------------------------------

resource "aws_launch_template" "nodes" {
  name = "${local.name_prefix}-node-template"

  vpc_security_group_ids = [
    var.node_sg_id,
    aws_eks_cluster.main.vpc_config[0].cluster_security_group_id,
  ]

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = var.node_disk_size
      volume_type = "gp3"
      encrypted   = true
    }
  }

  # [Checkov CKV_AWS_79 fix] IMDSv1 allows any process on the node
  # (including a compromised container that breaks out, or one relying on
  # a proxy misconfig) to fetch the node IAM role's credentials with a
  # plain unauthenticated GET - no request signing needed. IMDSv2 requires
  # a session token from a PUT first, which closes the most common
  # SSRF-to-credential-theft path. hop_limit=1 additionally stops a
  # container from reaching the node's IMDS through an extra network hop.
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    http_endpoint               = "enabled"
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      Name      = "${local.name_prefix}-node"
      Component = "compute"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(var.tags, {
      Name      = "${local.name_prefix}-node-volume"
      Component = "compute"
    })
  }

  tags = merge(var.tags, {
    Name      = "${local.name_prefix}-node-template"
    Component = "compute"
  })
}

# -----------------------------------------------------------------------------
# Managed Node Group
# -----------------------------------------------------------------------------

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${local.name_prefix}-nodes"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.subnet_ids

  instance_types = var.node_instance_types
  ami_type       = var.node_ami_type
  capacity_type  = var.node_capacity_type

  launch_template {
    id      = aws_launch_template.nodes.id
    version = aws_launch_template.nodes.latest_version
  }

  scaling_config {
    min_size     = var.node_min_size
    max_size     = var.node_max_size
    desired_size = var.node_desired_size
  }

  labels = {
    environment = var.environment
    managed-by  = "eks"
  }

  tags = merge(var.tags, {
    Name      = "${local.name_prefix}-nodes"
    Component = "compute"
  })

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
  ]
}

# -----------------------------------------------------------------------------
# EKS Add-ons (pinned versions resolved from cluster version)
# -----------------------------------------------------------------------------

data "aws_eks_addon_version" "coredns" {
  addon_name         = "coredns"
  kubernetes_version = aws_eks_cluster.main.version
  most_recent        = true
}

data "aws_eks_addon_version" "kube_proxy" {
  addon_name         = "kube-proxy"
  kubernetes_version = aws_eks_cluster.main.version
  most_recent        = true
}

data "aws_eks_addon_version" "vpc_cni" {
  addon_name         = "vpc-cni"
  kubernetes_version = aws_eks_cluster.main.version
  most_recent        = true
}

data "aws_eks_addon_version" "ebs_csi" {
  addon_name         = "aws-ebs-csi-driver"
  kubernetes_version = aws_eks_cluster.main.version
  most_recent        = true
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "coredns"
  addon_version               = data.aws_eks_addon_version.coredns.version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.main]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "kube-proxy"
  addon_version               = data.aws_eks_addon_version.kube_proxy.version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "vpc-cni"
  addon_version               = data.aws_eks_addon_version.vpc_cni.version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # [MED-003 fix] Without this, the NetworkPolicy objects in
  # k8s/base/network-policies/ are inert — the default VPC CNI only
  # enforces Security Groups (the perimeter model in ADR-0001), it does
  # not read or enforce Kubernetes NetworkPolicy resources on its own.
  configuration_values = jsonencode({
    enableNetworkPolicy = "true"
  })
}

# -----------------------------------------------------------------------------
# EBS CSI Driver — IRSA Role
# -----------------------------------------------------------------------------

resource "aws_iam_role" "ebs_csi" {
  name = "${local.name_prefix}-ebs-csi-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_provider_url}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
          "${local.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = merge(var.tags, {
    Name      = "${local.name_prefix}-ebs-csi-role"
    Component = "compute"
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.ebs_csi.name
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = data.aws_eks_addon_version.ebs_csi.version
  service_account_role_arn    = aws_iam_role.ebs_csi.arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.main]
}

# -----------------------------------------------------------------------------
# External Secrets Operator — IRSA Role (PETPLAT-37)
# -----------------------------------------------------------------------------

resource "aws_iam_role" "eso" {
  name = "${local.name_prefix}-eso-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_provider_url}:sub" = "system:serviceaccount:external-secrets:external-secrets-sa"
          "${local.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = merge(var.tags, {
    Name      = "${local.name_prefix}-eso-role"
    Component = "compute"
  })
}

resource "aws_iam_policy" "eso_secrets_access" {
  name        = "${local.name_prefix}-eso-secrets-policy"
  description = "Allow External Secrets Operator to read ${var.environment}-only secrets from Secrets Manager"

  # [HIGH-001 fix] Scoped to this environment's secrets only
  # (petclinic/dev/* or petclinic/prod/*), not the whole project
  # (petclinic/*). The prior wildcard let dev's ESO identity read prod
  # secrets and vice versa once both environments exist.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
        ]
        Resource = "arn:${data.aws_partition.current.partition}:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:${var.project}/${var.environment}/*"
      },
      {
        # [Checkov CKV_AWS_149 follow-up] Secrets are now encrypted with
        # customer-managed KMS keys (secrets/rds modules) instead of the
        # default AWS-managed key, so ESO needs explicit kms:Decrypt.
        # Resource "*" here is scoped tight by the ViaService condition -
        # this only works for a KMS call made *by* Secrets Manager during
        # GetSecretValue, not a direct kms:Decrypt call against any key.
        Sid      = "DecryptViaSecretsManagerOnly"
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "secretsmanager.${data.aws_region.current.name}.amazonaws.com"
          }
        }
      },
    ]
  })

  tags = merge(var.tags, {
    Name      = "${local.name_prefix}-eso-secrets-policy"
    Component = "compute"
  })
}

resource "aws_iam_role_policy_attachment" "eso" {
  policy_arn = aws_iam_policy.eso_secrets_access.arn
  role       = aws_iam_role.eso.name
}
