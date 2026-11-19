# Clickstream: Direct PUT -> S3. Partitioned by arrival time with prefix expressions
# (no dynamic partitioning, which costs extra).

resource "aws_cloudwatch_log_group" "firehose" {
  name              = "/aws/kinesisfirehose/${local.name}-clickstream"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_stream" "firehose" {
  name           = "DestinationDelivery"
  log_group_name = aws_cloudwatch_log_group.firehose.name
}

resource "aws_iam_role" "firehose" {
  name = "${local.name}-firehose"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "firehose.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "sts:ExternalId" = data.aws_caller_identity.current.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "firehose" {
  role = aws_iam_role.firehose.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:AbortMultipartUpload", "s3:GetBucketLocation", "s3:GetObject",
          "s3:ListBucket", "s3:ListBucketMultipartUploads", "s3:PutObject",
        ]
        Resource = [data.aws_s3_bucket.lake.arn, "${data.aws_s3_bucket.lake.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = "logs:PutLogEvents"
        Resource = "${aws_cloudwatch_log_group.firehose.arn}:*"
      },
    ]
  })
}

resource "aws_kinesis_firehose_delivery_stream" "clickstream" {
  name        = "${local.name}-clickstream"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn            = aws_iam_role.firehose.arn
    bucket_arn          = data.aws_s3_bucket.lake.arn
    prefix              = "landing/clickstream/dt=!{timestamp:yyyy-MM-dd}/hour=!{timestamp:HH}/"
    error_output_prefix = "errors/clickstream/!{firehose:error-output-type}/dt=!{timestamp:yyyy-MM-dd}/"
    buffering_size      = 5
    buffering_interval  = 60
    compression_format  = "GZIP"

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.firehose.name
      log_stream_name = aws_cloudwatch_log_stream.firehose.name
    }
  }
}

output "firehose_stream_name" {
  value = aws_kinesis_firehose_delivery_stream.clickstream.name
}
