# Karpenter module — implemented in E-14 (Scaling & Cost Optimization).

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  name_prefix    = "${var.project}-${var.environment}"
  node_role_name = element(split("/", var.node_role_arn), length(split("/", var.node_role_arn)) - 1)
}

# -----------------------------------------------------------------------------
# IRSA — Karpenter controller pod assumes this role via the karpenter
# ServiceAccount in kube-system. Trust policy is scoped to that exact
# ServiceAccount, using the real cluster OIDC provider (never hardcoded).
# -----------------------------------------------------------------------------

resource "aws_iam_role" "karpenter" {
  name = "${local.name_prefix}-karpenter-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${var.oidc_provider_url}:aud" = "sts.amazonaws.com"
          "${var.oidc_provider_url}:sub" = "system:serviceaccount:kube-system:karpenter"
        }
      }
    }]
  })

  tags = merge(var.tags, {
    Name      = "${local.name_prefix}-karpenter-role"
    Component = "scaling"
  })
}

# -----------------------------------------------------------------------------
# Controller permissions — EC2 Fleet API access to launch/terminate nodes,
# pricing lookups for Spot diversification, SSM for EKS-optimized AMI
# resolution, SQS to read interruption notices, and iam:PassRole scoped to
# ONLY the node instance profile (not "*") so Karpenter cannot be used to
# pass an unrelated, more-privileged role and escalate.
# -----------------------------------------------------------------------------

resource "aws_iam_role_policy" "karpenter_controller" {
  name = "${local.name_prefix}-karpenter-controller-policy"
  role = aws_iam_role.karpenter.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EC2NodeManagement"
        Effect = "Allow"
        Action = [
          "ec2:CreateLaunchTemplate",
          "ec2:CreateFleet",
          "ec2:RunInstances",
          "ec2:CreateTags",
          "ec2:TerminateInstances",
          "ec2:DeleteLaunchTemplate",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeInstances",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeSpotPriceHistory",
          "ec2:DescribeImages",
        ]
        Resource = "*"
      },
      {
        Sid      = "PassNodeRoleOnly"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = var.node_role_arn
      },
      {
        Sid    = "InstanceProfileManagement"
        Effect = "Allow"
        Action = [
          "iam:GetInstanceProfile",
          "iam:TagInstanceProfile",
        ]
        Resource = aws_iam_instance_profile.karpenter_node.arn
      },
      {
        Sid      = "EKSClusterRead"
        Effect   = "Allow"
        Action   = "eks:DescribeCluster"
        Resource = "arn:${data.aws_partition.current.partition}:eks:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:cluster/${var.cluster_name}"
      },
      {
        Sid      = "SSMAMIResolution"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "arn:${data.aws_partition.current.partition}:ssm:${data.aws_region.current.name}::parameter/aws/service/*"
      },
      {
        Sid      = "PricingLookup"
        Effect   = "Allow"
        Action   = "pricing:GetProducts"
        Resource = "*"
      },
      {
        Sid    = "InterruptionQueue"
        Effect = "Allow"
        Action = [
          "sqs:DeleteMessage",
          "sqs:GetQueueUrl",
          "sqs:GetQueueAttributes",
          "sqs:ReceiveMessage",
        ]
        Resource = aws_sqs_queue.karpenter_interruption.arn
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# Instance profile for Karpenter-launched nodes — reuses the SAME node IAM
# role the EKS managed node group already uses (not a new role), so
# Karpenter-provisioned nodes have identical cluster permissions.
# -----------------------------------------------------------------------------

resource "aws_iam_instance_profile" "karpenter_node" {
  name = "${local.name_prefix}-karpenter-node-profile"
  role = local.node_role_name

  tags = merge(var.tags, {
    Name      = "${local.name_prefix}-karpenter-node-profile"
    Component = "scaling"
  })
}

# -----------------------------------------------------------------------------
# SQS interruption queue — Karpenter polls this for Spot interruption,
# rebalance, instance-state-change, and scheduled-change notices, giving it
# time to gracefully drain a node before AWS reclaims it. 20-minute
# visibility timeout matches Karpenter's documented recommendation.
# -----------------------------------------------------------------------------

resource "aws_sqs_queue" "karpenter_interruption" {
  name                       = "${local.name_prefix}-karpenter-interruption"
  message_retention_seconds  = 300
  visibility_timeout_seconds = 1200

  tags = merge(var.tags, {
    Name      = "${local.name_prefix}-karpenter-interruption"
    Component = "scaling"
  })
}

# Without this policy, EventBridge rules can target the queue but delivery
# is silently denied — interruption events never reach Karpenter, so Spot
# terminations are not handled gracefully (pods just die with no warning).
resource "aws_sqs_queue_policy" "karpenter_interruption" {
  queue_url = aws_sqs_queue.karpenter_interruption.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowEventBridgePublish"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.karpenter_interruption.arn
      Condition = {
        ArnEquals = {
          "aws:SourceArn" = [
            aws_cloudwatch_event_rule.spot_interruption.arn,
            aws_cloudwatch_event_rule.rebalance_recommendation.arn,
            aws_cloudwatch_event_rule.instance_state_change.arn,
            aws_cloudwatch_event_rule.scheduled_change.arn,
          ]
        }
      }
    }]
  })
}

# -----------------------------------------------------------------------------
# EventBridge rules — route the 4 event types Karpenter needs to react to,
# all targeting the same interruption queue.
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "spot_interruption" {
  name        = "${local.name_prefix}-karpenter-spot-interruption"
  description = "EC2 Spot Instance Interruption Warning -> Karpenter interruption queue"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_rule" "rebalance_recommendation" {
  name        = "${local.name_prefix}-karpenter-rebalance"
  description = "EC2 Instance Rebalance Recommendation -> Karpenter interruption queue"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance Rebalance Recommendation"]
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_rule" "instance_state_change" {
  name        = "${local.name_prefix}-karpenter-instance-state-change"
  description = "EC2 Instance State-change Notification -> Karpenter interruption queue"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_rule" "scheduled_change" {
  name        = "${local.name_prefix}-karpenter-scheduled-change"
  description = "AWS Health scheduled change event -> Karpenter interruption queue"

  event_pattern = jsonencode({
    source      = ["aws.health"]
    detail-type = ["AWS Health Event"]
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "spot_interruption" {
  rule = aws_cloudwatch_event_rule.spot_interruption.name
  arn  = aws_sqs_queue.karpenter_interruption.arn
}

resource "aws_cloudwatch_event_target" "rebalance_recommendation" {
  rule = aws_cloudwatch_event_rule.rebalance_recommendation.name
  arn  = aws_sqs_queue.karpenter_interruption.arn
}

resource "aws_cloudwatch_event_target" "instance_state_change" {
  rule = aws_cloudwatch_event_rule.instance_state_change.name
  arn  = aws_sqs_queue.karpenter_interruption.arn
}

resource "aws_cloudwatch_event_target" "scheduled_change" {
  rule = aws_cloudwatch_event_rule.scheduled_change.name
  arn  = aws_sqs_queue.karpenter_interruption.arn
}
