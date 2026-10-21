# Hourly Harlyy pipeline, the same shape as coldstone-web:
#
#   Glue trigger (hourly) -> harlyy-extract (Glue) -> events topic (SNS)
#     -> load queue (SQS, + dead-letter queue) -> load dispatcher (Lambda)
#     -> harlyy-load (Glue) -> Redshift
#
# Failures (extract or load reporting failed, a Glue job failing or timing out,
# a message in the dead-letter queue, the dispatcher erroring) go to the alerts topic.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_redshiftserverless_workgroup" "this" {
  workgroup_name = var.redshift_workgroup_name
}

locals {
  extract_job_name = "${var.name_prefix}-extract"
  load_job_name    = "${var.name_prefix}-load"
  script_base      = "s3://${var.bucket_name}/${var.scripts_prefix}"
}

# ---- scripts -----------------------------------------------------------------
resource "aws_s3_object" "extract_script" {
  bucket = var.bucket_name
  key    = "${var.scripts_prefix}/harlyy_extract.py"
  source = var.extract_script_path
  etag   = filemd5(var.extract_script_path)
}

resource "aws_s3_object" "load_script" {
  bucket = var.bucket_name
  key    = "${var.scripts_prefix}/harlyy_load.py"
  source = var.load_script_path
  etag   = filemd5(var.load_script_path)
}

# ---- Glue role -----------------------------------------------------------------
data "aws_iam_policy_document" "glue_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "glue" {
  name               = "${var.name_prefix}-glue"
  assume_role_policy = data.aws_iam_policy_document.glue_assume.json
}

# Glue's own needs: CloudWatch logs and metrics for job runs.
resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

data "aws_iam_policy_document" "glue" {
  statement {
    sid       = "ListPipelineFolders"
    actions   = ["s3:ListBucket"]
    resources = [var.bucket_arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${var.s3_prefix}/*", "${var.scripts_prefix}/*"]
    }
  }

  statement {
    sid       = "ReadWritePipelineFiles"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${var.bucket_arn}/${var.s3_prefix}/*"]
  }

  statement {
    sid       = "ReadScripts"
    actions   = ["s3:GetObject"]
    resources = ["${var.bucket_arn}/${var.scripts_prefix}/*"]
  }

  statement {
    sid       = "ReadHarlyySecret"
    actions   = ["ssm:GetParameter"]
    resources = [var.harlyy_secret_param_arn]
  }

  statement {
    sid       = "PublishResults"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.events.arn, var.alerts_topic_arn]
  }

  statement {
    sid       = "RequeueLoads"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.load.arn]
  }

  statement {
    sid       = "RunRedshiftStatements"
    actions   = ["redshift-data:ExecuteStatement", "redshift-data:BatchExecuteStatement"]
    resources = [data.aws_redshiftserverless_workgroup.this.arn]
  }

  # These act on statement IDs, which have no ARN; the Data API only lets a caller
  # see statements it started itself.
  statement {
    sid       = "ReadRedshiftStatements"
    actions   = ["redshift-data:DescribeStatement", "redshift-data:GetStatementResult", "redshift-data:CancelStatement"]
    resources = ["*"]
  }

  statement {
    sid       = "RedshiftIamLogin"
    actions   = ["redshift-serverless:GetCredentials"]
    resources = [data.aws_redshiftserverless_workgroup.this.arn]
  }
}

resource "aws_iam_role_policy" "glue" {
  name   = "${var.name_prefix}-glue"
  role   = aws_iam_role.glue.id
  policy = data.aws_iam_policy_document.glue.json
}

# ---- Glue jobs ---------------------------------------------------------------------
resource "aws_glue_job" "extract" {
  name         = local.extract_job_name
  description  = "Harlyy API -> raw + Parquet on S3, hourly. See glue/harlyy_extract.py for one-off parameters."
  role_arn     = aws_iam_role.glue.arn
  glue_version = "3.0"
  max_capacity = 0.0625
  timeout      = var.extract_timeout_minutes
  max_retries  = 0

  command {
    name            = "pythonshell"
    python_version  = "3.9"
    script_location = "${local.script_base}/${aws_s3_object.extract_script.key}"
  }

  # A manual backfill can run while the hourly schedule carries on.
  execution_property {
    max_concurrent_runs = 2
  }

  default_arguments = {
    "--additional-python-modules" = var.python_modules
    "--S3_BUCKET"                 = var.bucket_name
    "--S3_PREFIX"                 = var.s3_prefix
    "--HARLYY_BUSINESS_ID"        = var.harlyy_business_id
    "--HARLYY_SECRET_PARAM"       = var.harlyy_secret_param_name
    "--REVIEWS_FROM"              = var.reviews_from
    "--EVENTS_TOPIC_ARN"          = aws_sns_topic.events.arn
    "--ALERTS_TOPIC_ARN"          = var.alerts_topic_arn
  }

}

resource "aws_glue_job" "load" {
  name         = local.load_job_name
  description  = "Harlyy Parquet on S3 -> Redshift (staging, checks, MERGE). Started by the load dispatcher."
  role_arn     = aws_iam_role.glue.arn
  glue_version = "3.0"
  max_capacity = 0.0625
  timeout      = var.load_timeout_minutes
  max_retries  = 0

  command {
    name            = "pythonshell"
    python_version  = "3.9"
    script_location = "${local.script_base}/${aws_s3_object.load_script.key}"
  }

  # One load at a time, so two runs never merge into the same tables together.
  execution_property {
    max_concurrent_runs = 1
  }

  default_arguments = {
    "--REDSHIFT_WORKGROUP" = var.redshift_workgroup_name
    "--REDSHIFT_DATABASE"  = var.redshift_database
    "--REDSHIFT_SCHEMA"    = var.redshift_schema
    "--STAGING_SCHEMA"     = var.staging_schema
    "--COPY_ROLE_ARN"      = var.copy_role_arn
    "--ALERTS_TOPIC_ARN"   = var.alerts_topic_arn
    "--LOAD_QUEUE_URL"     = aws_sqs_queue.load.url
  }

}

resource "aws_glue_trigger" "hourly" {
  name              = "${var.name_prefix}-hourly"
  description       = "Runs the Harlyy extract every hour."
  type              = "SCHEDULED"
  schedule          = var.schedule
  start_on_creation = var.schedule_enabled
  enabled           = var.schedule_enabled

  actions {
    job_name = aws_glue_job.extract.name
  }
}

# ---- extract -> load hand-off ----------------------------------------------------------
resource "aws_sns_topic" "events" {
  name = "${var.name_prefix}-events"
}

resource "aws_sqs_queue" "load_dlq" {
  name                      = "${var.name_prefix}-load-dlq"
  message_retention_seconds = 1209600 # 14 days, time to investigate
}

resource "aws_sqs_queue" "load" {
  name                       = "${var.name_prefix}-load-queue"
  visibility_timeout_seconds = 300 # a run that finds a load in progress is retried after this
  message_retention_seconds  = 345600

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.load_dlq.arn
    maxReceiveCount     = 12 # about an hour of retries before the dead-letter queue
  })
}

data "aws_iam_policy_document" "load_queue" {
  statement {
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.load.arn]
    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_sns_topic.events.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "load" {
  queue_url = aws_sqs_queue.load.id
  policy    = data.aws_iam_policy_document.load_queue.json
}

resource "aws_sns_topic_subscription" "load_queue" {
  topic_arn            = aws_sns_topic.events.arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.load.arn
  raw_message_delivery = true
  filter_policy = jsonencode({
    stage  = ["extract"]
    status = ["success"]
  })
}

# ---- load dispatcher -------------------------------------------------------------------
data "archive_file" "dispatcher" {
  type        = "zip"
  source_dir  = var.dispatcher_source_dir
  output_path = "${path.module}/.build/load_dispatcher.zip"
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dispatcher" {
  name               = "${var.name_prefix}-load-dispatcher"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_cloudwatch_log_group" "dispatcher" {
  name              = "/aws/lambda/${var.name_prefix}-load-dispatcher"
  retention_in_days = var.log_retention_days
}

data "aws_iam_policy_document" "dispatcher" {
  statement {
    sid       = "ReadLoadQueue"
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
    resources = [aws_sqs_queue.load.arn]
  }

  statement {
    sid       = "StartLoad"
    actions   = ["glue:StartJobRun"]
    resources = ["arn:aws:glue:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:job/${local.load_job_name}"]
  }

  statement {
    sid       = "WriteLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.dispatcher.arn}:*"]
  }
}

resource "aws_iam_role_policy" "dispatcher" {
  name   = "${var.name_prefix}-load-dispatcher"
  role   = aws_iam_role.dispatcher.id
  policy = data.aws_iam_policy_document.dispatcher.json
}

resource "aws_lambda_function" "dispatcher" {
  function_name    = "${var.name_prefix}-load-dispatcher"
  description      = "Starts the Harlyy load Glue job for each successful extract."
  role             = aws_iam_role.dispatcher.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.dispatcher.output_path
  source_code_hash = data.archive_file.dispatcher.output_base64sha256
  timeout          = 30

  environment {
    variables = { LOAD_JOB_NAME = aws_glue_job.load.name }
  }

  depends_on = [aws_cloudwatch_log_group.dispatcher]
}

resource "aws_lambda_event_source_mapping" "dispatcher" {
  event_source_arn        = aws_sqs_queue.load.arn
  function_name           = aws_lambda_function.dispatcher.arn
  batch_size              = 1
  function_response_types = ["ReportBatchItemFailures"]
}

# ---- failure alerts ----------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "glue_failed" {
  name        = "${var.name_prefix}-glue-failed"
  description = "A Harlyy Glue job failed, timed out or errored."

  event_pattern = jsonencode({
    source      = ["aws.glue"]
    detail-type = ["Glue Job State Change"]
    detail = {
      jobName = [aws_glue_job.extract.name, aws_glue_job.load.name]
      state   = ["FAILED", "TIMEOUT", "ERROR"]
    }
  })
}

resource "aws_cloudwatch_event_target" "glue_failed" {
  rule = aws_cloudwatch_event_rule.glue_failed.name
  arn  = var.alerts_topic_arn

  input_transformer {
    input_paths = {
      job     = "$.detail.jobName"
      state   = "$.detail.state"
      run     = "$.detail.jobRunId"
      message = "$.detail.message"
    }
    input_template = "\"Glue job <job> <state> (run <run>): <message>. Logs: AWS Glue console > Jobs > <job> > Runs.\""
  }
}

resource "aws_cloudwatch_metric_alarm" "dead_letters" {
  alarm_name          = "${var.name_prefix}-load-dead-letters"
  alarm_description   = "Harlyy loads that could not be started after about an hour of retries are in the dead-letter queue."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.load_dlq.name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alerts_topic_arn]
}

resource "aws_cloudwatch_metric_alarm" "dispatcher_errors" {
  alarm_name          = "${var.name_prefix}-load-dispatcher-errors"
  alarm_description   = "The Harlyy load dispatcher Lambda raised errors."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.dispatcher.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alerts_topic_arn]
}
