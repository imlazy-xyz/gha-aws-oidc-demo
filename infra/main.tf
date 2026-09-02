# Disposable demo workload: six free-tier resources chosen to exercise IAM breadth
# (identity policy, trust policy, and three distinct resource-policy types) at $0 cost.

locals {
  name = "gha-demo"
}

# --- S3 bucket + resource policy ----------------------------------------------------
resource "aws_s3_bucket" "app" {
  bucket = "${local.name}-app-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "app" {
  bucket                  = aws_s3_bucket.app.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "app" {
  bucket = aws_s3_bucket.app.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "app" {
  bucket = aws_s3_bucket.app.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowAppRoleReadWrite"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.app.arn }
        Action    = ["s3:GetObject", "s3:PutObject"]
        Resource  = "${aws_s3_bucket.app.arn}/*"
      }
    ]
  })
}

# --- SQS queue + resource policy ----------------------------------------------------
resource "aws_sqs_queue" "app" {
  name = "${local.name}-app-queue"
}

resource "aws_sqs_queue_policy" "app" {
  queue_url = aws_sqs_queue.app.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowAppRoleSendReceive"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.app.arn }
        Action    = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource  = aws_sqs_queue.app.arn
      }
    ]
  })
}

# --- SNS topic + resource policy ----------------------------------------------------
resource "aws_sns_topic" "app" {
  name = "${local.name}-app-topic"
}

resource "aws_sns_topic_policy" "app" {
  arn = aws_sns_topic.app.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowAppRolePublish"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.app.arn }
        Action    = ["sns:Publish"]
        Resource  = aws_sns_topic.app.arn
      }
    ]
  })
}

# --- DynamoDB table (identity-policy breadth, no resource policy) -------------------
resource "aws_dynamodb_table" "app" {
  name         = "${local.name}-app-table"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }
}

# --- CloudWatch log group ($0 at zero ingest) ----------------------------------------
resource "aws_cloudwatch_log_group" "app" {
  name              = "/${local.name}/app"
  retention_in_days = 1
}

# --- App IAM role: identity policy + trust policy for the validator to analyse ------
data "aws_iam_policy" "ci_boundary" {
  name = "gha-demo-ci-boundary"
}

resource "aws_iam_role" "app" {
  name                 = "${local.name}-app-role"
  path                 = "/gha-demo/"
  permissions_boundary = data.aws_iam_policy.ci_boundary.arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "app" {
  name = "${local.name}-app-policy"
  role = aws_iam_role.app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "S3ReadWrite"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "${aws_s3_bucket.app.arn}/*"
      },
      {
        Sid      = "QueueSendReceive"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = aws_sqs_queue.app.arn
      },
      {
        Sid      = "TopicPublish"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.app.arn
      },
      {
        Sid      = "TableReadWrite"
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:GetItem"]
        Resource = aws_dynamodb_table.app.arn
      },
      {
        Sid      = "LogWrite"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.app.arn}:*"
      }
    ]
  })
}
