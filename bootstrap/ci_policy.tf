# CI role permissions policy -- starting point, deliberately incomplete.
#
# This is refined in Phase 3 by running terraform apply (via a locally-assumed CI role,
# see README) and reading real AccessDenied errors. Each denial + fix is recorded in the
# README rather than jumping straight to a working policy.

resource "aws_iam_role_policy" "ci_workload" {
  name = "gha-demo-ci-workload"
  role = aws_iam_role.ci.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "WorkloadResources"
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
        Sid    = "AccessAnalyzerValidator"
        Effect = "Allow"
        Action = [
          "access-analyzer:ValidatePolicy",
          "access-analyzer:CheckNoNewAccess",
          "access-analyzer:CheckAccessNotGranted",
          "access-analyzer:CheckNoPublicAccess",
        ]
        Resource = "*"
      },
      {
        Sid    = "StateBucket"
        Effect = "Allow"
        Action = ["s3:*"]
        Resource = [
          aws_s3_bucket.tf_state.arn,
          "${aws_s3_bucket.tf_state.arn}/*",
        ]
      },
      {
        Sid    = "AppRoleManagement"
        Effect = "Allow"
        Action = ["iam:*"]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/gha-demo/*"
      }
    ]
  })
}
