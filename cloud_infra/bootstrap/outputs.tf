output "state_bucket_name" {
  description = "Put this in ../backend.hcl as bucket."
  value       = module.state_bucket.bucket_name
}

output "state_bucket_arn" {
  description = "ARN of the state bucket."
  value       = module.state_bucket.bucket_arn
}
