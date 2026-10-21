locals {
  # coldstone-redshift-s3-read-role etc.: the policy is attached by role name.
  redshift_copy_role_name = element(split("/", var.redshift_copy_role_arn), length(split("/", var.redshift_copy_role_arn)) - 1)
}

# Raw files, processed Parquet, manifests and the Glue scripts.
module "s3_bucket" {
  source = "./modules/s3_bucket"

  bucket_name                        = var.bucket_name
  versioning_enabled                 = var.versioning_enabled
  kms_key_arn                        = var.kms_key_arn
  noncurrent_version_expiration_days = var.noncurrent_version_expiration_days
  force_destroy                      = var.force_destroy
}

# Harlyy client secret, read by the extract job. Terraform creates it with a
# placeholder; the real value is set once with aws ssm put-parameter.
module "harlyy_secret" {
  source = "./modules/ssm_parameter"

  name        = var.harlyy_secret_param_name
  description = "Harlyy API client secret, used as the Bearer token by the Harlyy extract."
}

# Lets Redshift COPY (through the role on the namespace) read the Parquet files.
module "redshift_s3_access" {
  source = "./modules/redshift_s3_access"

  role_name   = local.redshift_copy_role_name
  policy_name = "${var.project}-read-processed"
  bucket_arn  = module.s3_bucket.bucket_arn
  read_prefix = "${var.s3_prefix}/processed"
  kms_key_arn = var.kms_key_arn
}

# Failure emails.
module "alerts" {
  source = "./modules/alerts"

  topic_name   = "${var.project}-alerts"
  alert_emails = var.alert_emails
}

# Hourly Glue extract -> SNS -> SQS -> dispatcher Lambda -> Glue load -> Redshift.
module "glue_pipeline" {
  source = "./modules/glue_pipeline"

  name_prefix = var.project

  bucket_name           = module.s3_bucket.bucket_name
  bucket_arn            = module.s3_bucket.bucket_arn
  s3_prefix             = var.s3_prefix
  extract_script_path   = "${path.root}/../glue/harlyy_extract.py"
  load_script_path      = "${path.root}/../glue/harlyy_load.py"
  dispatcher_source_dir = "${path.root}/../lambda/load_dispatcher"

  harlyy_business_id       = var.harlyy_business_id
  harlyy_secret_param_name = module.harlyy_secret.name
  harlyy_secret_param_arn  = module.harlyy_secret.arn
  reviews_from             = var.reviews_from

  redshift_workgroup_name = var.redshift_workgroup_name
  redshift_database       = var.redshift_database
  redshift_schema         = var.redshift_schema
  staging_schema          = var.staging_schema
  copy_role_arn           = var.redshift_copy_role_arn

  schedule         = var.schedule
  schedule_enabled = var.schedule_enabled
  alerts_topic_arn = module.alerts.topic_arn
}
