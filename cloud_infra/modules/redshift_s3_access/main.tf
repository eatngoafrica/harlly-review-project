# Lets Redshift COPY read the pipeline's Parquet files. Attached to the IAM
# role already associated with the Redshift Serverless namespace, so the
# namespace itself is not managed (or changed) here.

data "aws_iam_policy_document" "this" {
  statement {
    sid       = "ListProcessedPrefix"
    actions   = ["s3:ListBucket"]
    resources = [var.bucket_arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${var.read_prefix}", "${var.read_prefix}/*"]
    }
  }

  statement {
    sid       = "BucketLocation"
    actions   = ["s3:GetBucketLocation"]
    resources = [var.bucket_arn]
  }

  statement {
    sid       = "ReadProcessedFiles"
    actions   = ["s3:GetObject"]
    resources = ["${var.bucket_arn}/${var.read_prefix}/*"]
  }

  dynamic "statement" {
    for_each = var.kms_key_arn == null ? [] : [var.kms_key_arn]

    content {
      sid       = "DecryptBucketKey"
      actions   = ["kms:Decrypt"]
      resources = [statement.value]
    }
  }
}

resource "aws_iam_role_policy" "this" {
  name   = var.policy_name
  role   = var.role_name
  policy = data.aws_iam_policy_document.this.json
}
