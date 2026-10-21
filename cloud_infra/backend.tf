# State is stored in the S3 bucket created by ./bootstrap.
# Backend blocks cannot read variables, so the settings live in backend.hcl:
#   terraform init -backend-config=backend.hcl
terraform {
  backend "s3" {}
}
