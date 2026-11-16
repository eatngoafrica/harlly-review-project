variable "bucket_name" {
  description = "Globally unique S3 bucket name."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "Bucket name must be 3-63 characters of lowercase letters, numbers, dots and hyphens, starting and ending with a letter or number."
  }
}

variable "versioning_enabled" {
  description = "Keep previous versions of overwritten or deleted objects."
  type        = bool
  default     = true
}

variable "kms_key_arn" {
  description = "KMS key ARN for encryption. Null uses S3-managed keys (SSE-S3)."
  type        = string
  default     = null
}

variable "noncurrent_version_expiration_days" {
  description = "Days to keep previous object versions. 0 keeps them forever."
  type        = number
  default     = 90

  validation {
    condition     = var.noncurrent_version_expiration_days >= 0
    error_message = "noncurrent_version_expiration_days cannot be negative."
  }
}

variable "force_destroy" {
  description = "Allow deleting the bucket while it still holds objects."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags for the bucket, on top of the provider's default tags."
  type        = map(string)
  default     = {}
}
