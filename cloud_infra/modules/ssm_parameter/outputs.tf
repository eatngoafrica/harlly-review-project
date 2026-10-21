output "name" {
  description = "Parameter name, for HARLYY_SECRET_PARAM."
  value       = aws_ssm_parameter.this.name
}

output "arn" {
  description = "Parameter ARN, for IAM policies."
  value       = aws_ssm_parameter.this.arn
}
