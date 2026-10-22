# Fill in these values before running terraform plan / apply.

aws_region  = "us-east-1"
aws_profile = "eatngo"

project     = "eatngo-harlyy-feedback"
environment = "prod"

bucket_name = "eatngo-harlyy-feedback"

# Optional: the defaults below are the secure choice; change only if needed.
versioning_enabled                 = true
kms_key_arn                        = null # a KMS key ARN, or null for S3-managed encryption
noncurrent_version_expiration_days = 90   # 0 keeps old versions forever
force_destroy                      = false

# Harlyy
harlyy_business_id       = "bus_697b58184eb7844dba40fce0"
harlyy_secret_param_name = "/harlyy-feedback/prod/harlyy-client-secret"
reviews_from             = "2026-01-01" # reviews posted before this are never loaded
s3_prefix                = "harlyy"

# Redshift
redshift_workgroup_name = "eatngo-analytics"
redshift_database       = "eatngo"
redshift_schema         = "harlyy_feedback_analytics"
staging_schema          = "harlyy_feedback_staging"
redshift_copy_role_arn  = "arn:aws:iam::655103423742:role/coldstone-redshift-s3-read-role"

# Schedule: Glue cron in UTC (Lagos is UTC+1, so hour boundaries line up).
schedule = "cron(5 * * * ? *)"

schedule_enabled = true
# Failure emails (each address must confirm the AWS subscription email)
alert_emails = ["chinyere.nwigwe@eatngo-africa.com"]

tags = {
  Owner      = "chinyere.nwigwe@eatngo-africa.com"
  aws-apn-id = "65jiyh5muw5om1whvryxkbpyd"
}
