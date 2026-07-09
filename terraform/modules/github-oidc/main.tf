data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

# -----------------------------------------------------------------------------
# OIDC Provider — federated trust between GitHub Actions and AWS.
# No long-lived AWS keys are ever stored in GitHub; the workflow requests a
# short-lived token (valid ~1h) directly from AWS at run time.
#
# This is a DATA lookup, not a resource, because AWS allows only one OIDC
# provider per URL per account, and token.actions.githubusercontent.com is
# the same URL for every GitHub Actions workflow account-wide — not scoped
# to this project. This account already has one (pre-existing, belonging to
# an unrelated project). Creating a second one fails with EntityAlreadyExists;
# importing the existing one into this module's state would let a future
# `terraform destroy` here delete infrastructure another project depends on.
# Referencing it as data avoids both: we never create or destroy it, only
# read its ARN to build our own role's trust policy. This is safe — the
# provider itself doesn't grant access to anything; the IAM role's own trust
# policy condition below (scoped to this specific repo/branch) is what
# actually controls who can assume it.
# -----------------------------------------------------------------------------

data "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}

# -----------------------------------------------------------------------------
# IAM Role — assumable only by the build-push.yml workflow running on the
# `main` branch of the application repo fork (not the platform repo, not any
# other branch, not any other repo). This trust condition is the entire
# security boundary of the whole CI pipeline.
# -----------------------------------------------------------------------------

resource "aws_iam_role" "github_actions" {
  name = "${var.project}-github-actions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = data.aws_iam_openid_connect_provider.github_actions.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:${var.app_repo_github_owner}/${var.app_repo_name}:ref:refs/heads/main"
        }
      }
    }]
  })

  tags = merge(var.tags, {
    Name      = "${var.project}-github-actions-role"
    Component = "cicd"
  })
}

# -----------------------------------------------------------------------------
# IAM Policy — ECR push only. No ecr:*, no *. GetAuthorizationToken is an
# account-level action that AWS requires Resource: "*" for (it cannot be
# scoped to a repository ARN); every other action is scoped to this
# project's ECR repositories only.
# -----------------------------------------------------------------------------

resource "aws_iam_role_policy" "ecr_push" {
  name = "${var.project}-github-actions-ecr-push"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ECRAuthToken"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "ECRPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
        ]
        Resource = "arn:${data.aws_partition.current.partition}:ecr:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:repository/${var.project}-*"
      }
    ]
  })
}
