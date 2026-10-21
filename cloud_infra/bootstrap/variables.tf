variable "aws_region" {
  description = "AWS region for the state bucket; use the same region as the main config."
  type        = string
}

variable "aws_profile" {
  description = "AWS CLI profile to deploy with. Leave null to use AWS_PROFILE or the default credentials."
  type        = string
  default     = null
}

variable "project" {
  description = "Project name, used in tags."
  type        = string
}

variable "environment" {
  description = "Environment name, e.g. prod. Used in tags."
  type        = string
}

variable "state_bucket_name" {
  description = "Globally unique name for the Terraform state bucket."
  type        = string
}

variable "state_version_retention_days" {
  description = "Days to keep previous versions of state files, for rollback."
  type        = number
  default     = 365
}

variable "tags" {
  description = "Extra tags for the state bucket."
  type        = map(string)
  default     = {}
}
