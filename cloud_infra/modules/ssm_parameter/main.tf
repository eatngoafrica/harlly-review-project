# A SecureString whose real value is set outside Terraform, so the secret
# never appears in code or in the Terraform state:
#   aws ssm put-parameter --name <name> --type SecureString --overwrite --value '<secret>'
resource "aws_ssm_parameter" "this" {
  name        = var.name
  description = var.description
  type        = "SecureString"
  key_id      = var.kms_key_id
  value       = "CHANGE_ME" # placeholder only

  lifecycle {
    ignore_changes = [value]
  }
}
