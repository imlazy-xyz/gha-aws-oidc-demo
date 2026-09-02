output "bucket_name" {
  value = aws_s3_bucket.app.id
}

output "queue_url" {
  value = aws_sqs_queue.app.id
}

output "topic_arn" {
  value = aws_sns_topic.app.arn
}

output "table_name" {
  value = aws_dynamodb_table.app.id
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.app.name
}

output "app_role_arn" {
  value = aws_iam_role.app.arn
}
