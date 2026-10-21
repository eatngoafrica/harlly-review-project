variable "role_name" {
  description = "Name (not ARN) of the IAM role associated with the Redshift Serverless namespace."
  type        = string
}

variable "policy_name" {
  description = "Name of the inline policy added to that role."
  type        = string
}

variable "bucket_arn" {
  description = "ARN of the bucket holding the Parquet files."
  type        = string
}

variable "read_prefix" {
  description = "Key prefix Redshift may read, without leading or trailing slash, e.g. harlyy/processed."
  type        = string

  validation {
    condition     = !startswith(var.read_prefix, "/") && !endswith(var.read_prefix, "/")
    error_message = "read_prefix must not start or end with a slash."
  }
}

variable "kms_key_arn" {
  description = "KMS key the bucket is encrypted with, or null for S3-managed keys."
  type        = string
  default     = null
}
