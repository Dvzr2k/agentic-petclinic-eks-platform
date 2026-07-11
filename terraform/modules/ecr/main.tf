locals {
  name_prefix = "${var.project}-${var.environment}"
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# [Checkov CKV_AWS_136 fix] Was AES256 (the default, AWS-owned key) -
# switched to a customer-managed key so access to decrypt image layers is
# controlled the same way as everything else in this project (IAM +
# explicit key policy) rather than the un-scoped default.
resource "aws_kms_key" "ecr" {
  description         = "Encryption for ${local.name_prefix} ECR repositories"
  enable_key_rotation = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "EnableRootAccountAccess"
      Effect    = "Allow"
      Principal = { AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root" }
      Action    = "kms:*"
      Resource  = "*"
    }]
  })

  tags = merge(var.tags, {
    Name      = "${local.name_prefix}-ecr-key"
    Component = "registry"
  })
}

resource "aws_ecr_repository" "service" {
  for_each = toset(var.service_names)

  name                 = "${local.name_prefix}/${each.value}"
  image_tag_mutability = var.image_tag_mutability
  force_delete         = var.force_delete

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.ecr.arn
  }

  tags = merge(var.tags, {
    Name      = "${local.name_prefix}/${each.value}"
    Component = "registry"
    Service   = each.value
  })
}

resource "aws_ecr_lifecycle_policy" "service" {
  for_each = aws_ecr_repository.service

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Keep last 10 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
