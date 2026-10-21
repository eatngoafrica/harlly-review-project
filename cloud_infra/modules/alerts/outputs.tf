output "topic_arn" {
  description = "SNS topic ARN for failure alerts."
  value       = aws_sns_topic.this.arn
}
