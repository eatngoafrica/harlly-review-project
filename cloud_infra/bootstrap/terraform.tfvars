# Fill in before running terraform apply in this folder (one time only).

aws_region  = "us-east-1"
aws_profile = "eatngo"

project     = "eatngo-harlyy-feedback"
environment = "prod"

state_bucket_name = "eatngo-terraform-statefile" # globally unique, e.g. "eatngo-terraform-state-prod"

state_version_retention_days = 365

tags = {
  Owner      = "chinyere.nwigwe@eatngo-africa.com"
  aws-apn-id = "65jiyh5muw5om1whvryxkbpyd"
}
