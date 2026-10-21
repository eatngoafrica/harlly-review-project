# Used by: terraform init -backend-config=backend.hcl

bucket       = "eatngo-terraform-statefile"             # state_bucket_name from ./bootstrap
key          = "harlyy-feedback/prod/terraform.tfstate" # path of the state file inside the bucket
region       = "us-east-1"
profile      = "eatngo"
encrypt      = true
use_lockfile = true # S3 lock file stops two people applying at once
