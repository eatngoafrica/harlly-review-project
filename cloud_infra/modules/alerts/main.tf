# Failure alerts: everything published to this topic is emailed to the subscribers.
# Each subscriber must click the confirmation link AWS emails them first.
#
# Publishers: the Glue jobs (extract/load failures, with details), EventBridge
# (a Glue job failing or timing out) and CloudWatch alarms (dead-letter queue,
# dispatcher errors). Only failures are sent; successes are logged, not emailed.

data "aws_caller_identity" "current" {}

resource "aws_sns_topic" "this" {
  name = var.topic_name
}

data "aws_iam_policy_document" "topic" {
  statement {
    sid       = "AllowEventBridgeAndAlarmsFromThisAccount"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.this.arn]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "cloudwatch.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  # Keep the account's own IAM principals (the Glue role) able to publish.
  statement {
    sid       = "AllowThisAccount"
    actions   = ["sns:Publish", "sns:Subscribe", "sns:GetTopicAttributes"]
    resources = [aws_sns_topic.this.arn]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
}

resource "aws_sns_topic_policy" "this" {
  arn    = aws_sns_topic.this.arn
  policy = data.aws_iam_policy_document.topic.json
}

resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.alert_emails)

  topic_arn = aws_sns_topic.this.arn
  protocol  = "email"
  endpoint  = each.value
}
