output "extract_job_name" {
  description = "Glue job to run for one-off extracts (--full-history true, --hour, ...)."
  value       = aws_glue_job.extract.name
}

output "load_job_name" {
  description = "Glue job that loads Redshift."
  value       = aws_glue_job.load.name
}

output "glue_role_name" {
  description = "Redshift sees the Glue jobs as database user IAMR:<this name>; see sql/redshift/02_grants.sql."
  value       = aws_iam_role.glue.name
}

output "events_topic_arn" {
  description = "Extract success messages (feed the load queue)."
  value       = aws_sns_topic.events.arn
}

output "load_queue_url" {
  description = "SQS load queue."
  value       = aws_sqs_queue.load.url
}

output "load_dlq_url" {
  description = "Dead-letter queue: loads that could not be started."
  value       = aws_sqs_queue.load_dlq.url
}
