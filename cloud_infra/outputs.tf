output "bucket_name" {
  description = "Bucket holding raw, processed, manifests and the Glue scripts."
  value       = module.s3_bucket.bucket_name
}

output "harlyy_secret_param_name" {
  description = "Set the real Harlyy secret here once: aws ssm put-parameter --overwrite ..."
  value       = module.harlyy_secret.name
}

output "alerts_topic_arn" {
  description = "SNS topic that emails failures."
  value       = module.alerts.topic_arn
}

output "extract_job_name" {
  description = "Glue job for one-off runs: --full-history true, --hour, --date, --reviews-from."
  value       = module.glue_pipeline.extract_job_name
}

output "load_job_name" {
  description = "Glue job that loads Redshift (started by the dispatcher)."
  value       = module.glue_pipeline.load_job_name
}

output "glue_role_name" {
  description = "Redshift database user is IAMR:<this>; grant it access with sql/redshift/02_grants.sql."
  value       = module.glue_pipeline.glue_role_name
}

output "load_dlq_url" {
  description = "Dead-letter queue: loads that could not be started."
  value       = module.glue_pipeline.load_dlq_url
}
