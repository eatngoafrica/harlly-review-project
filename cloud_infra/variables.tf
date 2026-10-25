variable "aws_region" {
  description = "AWS region to create the bucket in, e.g. us-east-1."
  type        = string
}

variable "aws_profile" {
  description = "AWS CLI profile to deploy with (e.g. prod). Leave null to use AWS_PROFILE or the default credentials."
  type        = string
  default     = null
}

variable "project" {
  description = "Project name, used in tags."
  type        = string
}

variable "environment" {
  description = "Environment name, e.g. prod or dev. Used in tags."
  type        = string
}

variable "bucket_name" {
  description = "Globally unique S3 bucket name: 3-63 characters, lowercase letters, numbers, dots and hyphens."
  type        = string
}

variable "versioning_enabled" {
  description = "Keep previous versions of overwritten or deleted objects."
  type        = bool
  default     = true
}

variable "kms_key_arn" {
  description = "KMS key ARN for encryption. Leave null to use S3-managed keys (SSE-S3)."
  type        = string
  default     = null
}

variable "noncurrent_version_expiration_days" {
  description = "Days to keep previous object versions before deleting them. Set to 0 to keep them forever."
  type        = number
  default     = 90
}

variable "force_destroy" {
  description = "Allow terraform destroy to delete the bucket even when it still holds objects."
  type        = bool
  default     = false
}

variable "s3_prefix" {
  description = "Key prefix the pipeline writes under in the bucket (S3_PREFIX)."
  type        = string
  default     = "harlyy"
}

variable "harlyy_secret_param_name" {
  description = "SSM SecureString name for the Harlyy client secret (HARLYY_SECRET_PARAM)."
  type        = string
  default     = "/harlyy-feedback/prod/harlyy-client-secret"
}

variable "harlyy_business_id" {
  description = "Harlyy business ID (not a secret; it appears in Harlyy URLs)."
  type        = string
}

variable "reviews_from" {
  description = "A full-history run loads reviews posted from this date. Hourly runs keep every review Harlyy changes, whatever its age."
  type        = string
  default     = "2026-01-01"
}

variable "redshift_workgroup_name" {
  description = "Existing Redshift Serverless workgroup."
  type        = string
  default     = "eatngo-analytics"
}

variable "redshift_database" {
  description = "Existing Redshift database the harlyy_feedback_analytics schema is created in."
  type        = string

  validation {
    condition     = length(trimspace(var.redshift_database)) > 0
    error_message = "Set redshift_database to the existing database name."
  }
}

variable "redshift_schema" {
  description = "Target schema."
  type        = string
  default     = "harlyy_feedback_analytics"
}

variable "staging_schema" {
  description = "Staging schema used by the load."
  type        = string
  default     = "harlyy_feedback_staging"
}

variable "redshift_copy_role_arn" {
  description = "IAM role associated with the Redshift namespace that COPY uses to read S3; it is given read access to the processed files."
  type        = string

  validation {
    condition     = can(regex("^arn:aws:iam::\\d{12}:role/.+", var.redshift_copy_role_arn))
    error_message = "redshift_copy_role_arn must be an IAM role ARN."
  }
}

variable "schedule" {
  description = "When the extract runs, as a Glue cron in UTC. Default: 5 minutes past every hour."
  type        = string
  default     = "cron(5 * * * ? *)"
}

variable "schedule_enabled" {
  description = "Start the hourly trigger. Set false to deploy without running yet (e.g. before the backfill)."
  type        = bool
  default     = true
}

variable "alert_emails" {
  description = "Email addresses that receive failure alerts."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Extra tags for every resource, e.g. { Owner = \"data-team\" }."
  type        = map(string)
  default     = {}
}
