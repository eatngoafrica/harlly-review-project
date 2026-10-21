output "policy_name" {
  description = "Inline policy added to the Redshift role."
  value       = aws_iam_role_policy.this.name
}
