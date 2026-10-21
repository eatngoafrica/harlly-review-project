# One-time setup: creates the bucket that holds the main configuration's
# Terraform state. Its own state stays local, in this folder.

module "state_bucket" {
  source = "../modules/s3_bucket"

  bucket_name = var.state_bucket_name
  # Versioning lets a broken or deleted state file be restored.
  versioning_enabled                 = true
  noncurrent_version_expiration_days = var.state_version_retention_days
  force_destroy                      = false
}
