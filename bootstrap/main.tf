# Bootstrap: OIDC provider, CI role, permissions boundary, Terraform state bucket.
#
# Applied ONCE, LOCALLY, by a human with existing AWS credentials. This creates the
# state bucket that infra/backend.tf points at, so it cannot itself use an S3 backend
# (chicken-and-egg) -- state for this config is local only.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}

# --- OIDC provider -----------------------------------------------------------------
#
# No thumbprint_list: AWS validates the GitHub OIDC JWKS endpoint TLS certificate
# against its own library of trusted root CAs rather than a configured thumbprint.
# https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc_verify-thumbprint.html
# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_openid_connect_provider
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = []
}

# --- Permissions boundary for the CI role -------------------------------------------
#
# The workload creates an IAM role (infra/ app role), so the CI role needs iam:CreateRole
# etc. A permissions boundary caps anything the CI role creates so it can never mint a
# role with privileges the CI role itself does not already have, closing the obvious
# privilege-escalation path opened by granting iam:CreateRole.
resource "aws_iam_policy" "ci_boundary" {
  name        = "gha-demo-ci-boundary"
  description = "Permissions boundary for roles created by the GitHub Actions CI role"

  # NOTE: this boundary is attached to the CI role itself (see aws_iam_role.ci below),
  # not only to roles the CI role creates. That means it also caps what the CI role can
  # do directly -- iteration 2 of Phase 3 hit this: the boundary blocked the CI role's
  # own iam:ListPolicies / iam:GetPolicy calls (needed to look up this very policy by
  # name) even though the CI role's identity policy granted them. iam read/write actions
  # scoped to the /gha-demo/ path are included here for that reason.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowDemoWorkloadActions"
        Effect = "Allow"
        Action = [
          "s3:*",
          "sqs:*",
          "sns:*",
          "dynamodb:*",
          "logs:*",
        ]
        Resource = "*"
      },
      {
        Sid      = "AllowIamListForBoundaryLookup"
        Effect   = "Allow"
        Action   = ["iam:ListPolicies"]
        Resource = "*"
      },
      {
        Sid    = "AllowIamManagementUnderPath"
        Effect = "Allow"
        Action = [
          "iam:GetPolicy",
          "iam:GetPolicyVersion",
          "iam:GetRole",
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:UpdateRole",
          "iam:PutRolePolicy",
          "iam:GetRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies",
          "iam:ListInstanceProfilesForRole",
        ]
        Resource = [
          "arn:aws:iam::*:role/gha-demo/*",
          "arn:aws:iam::*:policy/gha-demo-ci-boundary",
        ]
      }
    ]
  })
}

# --- CI role -------------------------------------------------------------------------
#
# Trust policy tightened to StringEquals on the exact `sub` observed from a live token
# issued for the "aws-demo" GitHub environment (see README Phase 2). This repo was
# created after GitHub's 2026-07-15 cutover, so the sub uses the immutable-ID format
# (owner@owner-id/repo@repo-id) rather than the legacy owner/repo form -- a loose
# StringLike on "repo:imlazy-xyz/gha-aws-oidc-demo:*" was used only to discover this
# value and is intentionally not what ships here.
resource "aws_iam_role" "ci" {
  name                 = "gha-demo-ci-role"
  path                 = "/gha-demo/"
  permissions_boundary = aws_iam_policy.ci_boundary.arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
            "token.actions.githubusercontent.com:sub" = "repo:imlazy-xyz@1752641/gha-aws-oidc-demo@1354514600:environment:aws-demo"
          }
        }
      }
    ]
  })
}

# --- Terraform state bucket -----------------------------------------------------------
resource "aws_s3_bucket" "tf_state" {
  bucket = "gha-demo-tfstate-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket                  = aws_s3_bucket.tf_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.github.arn
}

output "ci_role_arn" {
  value = aws_iam_role.ci.arn
}

output "state_bucket" {
  value = aws_s3_bucket.tf_state.id
}
