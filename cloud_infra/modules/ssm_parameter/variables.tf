variable "name" {
  description = "Parameter name, e.g. /harlyy-feedback/prod/harlyy-client-secret."
  type        = string

  validation {
    condition     = startswith(var.name, "/")
    error_message = "Use a path-style name starting with /, e.g. /harlyy-feedback/prod/harlyy-client-secret."
  }
}

variable "description" {
  description = "What the parameter holds."
  type        = string
  default     = null
}

variable "kms_key_id" {
  description = "KMS key for encryption. Null uses the AWS-managed aws/ssm key."
  type        = string
  default     = null
}
