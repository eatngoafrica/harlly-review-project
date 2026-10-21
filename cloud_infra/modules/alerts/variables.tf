variable "topic_name" {
  description = "SNS topic name."
  type        = string
}

variable "alert_emails" {
  description = "Email addresses that receive failure alerts."
  type        = list(string)
  default     = []
}
