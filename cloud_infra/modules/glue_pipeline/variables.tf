variable "name_prefix" {
  description = "Prefix for every resource name, e.g. eatngo-harlyy-feedback."
  type        = string
}

# ---- S3 ----------------------------------------------------------------------
variable "bucket_name" {
  description = "Bucket for raw files, processed Parquet, manifests and the Glue scripts."
  type        = string
}

variable "bucket_arn" {
  description = "ARN of that bucket."
  type        = string
}

variable "s3_prefix" {
  description = "Folder the pipeline writes under (raw/, processed/, manifests/)."
  type        = string
  default     = "harlyy"
}

variable "scripts_prefix" {
  description = "Folder the Glue scripts are uploaded to."
  type        = string
  default     = "glue-scripts"
}

variable "extract_script_path" {
  description = "Local path of glue/harlyy_extract.py."
  type        = string
}

variable "load_script_path" {
  description = "Local path of glue/harlyy_load.py."
  type        = string
}

variable "dispatcher_source_dir" {
  description = "Local folder with the load dispatcher Lambda (handler.py)."
  type        = string
}

# ---- Harlyy ------------------------------------------------------------------
variable "harlyy_business_id" {
  description = "Harlyy business ID."
  type        = string
}

variable "harlyy_secret_param_name" {
  description = "SSM SecureString holding the Harlyy client secret."
  type        = string
}

variable "harlyy_secret_param_arn" {
  description = "ARN of that parameter."
  type        = string
}

variable "reviews_from" {
  description = "Reviews posted before this date are never loaded; hourly runs use it. Lower it before backfilling older reviews."
  type        = string
  default     = "2026-01-01"

  validation {
    condition     = can(regex("^\\d{4}(-\\d{2}-\\d{2})?$", var.reviews_from))
    error_message = "reviews_from must be a year (2026) or a date (2026-01-01)."
  }
}

# ---- Redshift ----------------------------------------------------------------
variable "redshift_workgroup_name" {
  description = "Existing Redshift Serverless workgroup."
  type        = string
}

variable "redshift_database" {
  description = "Existing database the tables live in."
  type        = string
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

variable "copy_role_arn" {
  description = "IAM role associated with the namespace that Redshift COPY uses to read S3."
  type        = string
}

# ---- running -----------------------------------------------------------------
variable "schedule" {
  description = "When the extract runs, as a Glue cron in UTC. Default: 5 minutes past every hour."
  type        = string
  default     = "cron(5 * * * ? *)"
}

variable "schedule_enabled" {
  description = "Start the hourly trigger. Set false to create everything without running it yet."
  type        = bool
  default     = true
}

# Glue's Python shell ships an old boto3 that does not know Redshift Serverless
# (WorkgroupName), so both jobs pin the version coldstone-web's load jobs use.
variable "extract_python_modules" {
  description = "Extra Python packages for the extract job (--additional-python-modules)."
  type        = string
  default     = "pyarrow==17.0.0,boto3==1.35.99"
}

variable "load_python_modules" {
  description = "Extra Python packages for the load job (--additional-python-modules)."
  type        = string
  default     = "boto3==1.35.99"
}

variable "extract_timeout_minutes" {
  description = "Extract job timeout; a full-history run takes a few minutes."
  type        = number
  default     = 60
}

variable "load_timeout_minutes" {
  description = "Load job timeout."
  type        = number
  default     = 60
}

variable "alerts_topic_arn" {
  description = "SNS topic that emails failures."
  type        = string
}

variable "log_retention_days" {
  description = "Days to keep the dispatcher Lambda's logs."
  type        = number
  default     = 30
}
