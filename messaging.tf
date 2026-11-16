############################
# Order events: SNS topic -> SQS queues (fan-out) -> consumers
#   One publisher, many independent consumers. Each queue has its own
#   retry policy and dead-letter queue, so a slow consumer never blocks others.
############################
resource "aws_sns_topic" "order_events" {
  name              = "${local.name}-order-events"
  kms_master_key_id = "alias/aws/sns"
}

locals {
  # Each consumer gets a queue; filter_events decides which events it receives.
  consumers = {
    notifications = {
      filter_events = ["order_placed", "order_shipped", "order_delivered", "order_cancelled"]
    }
    fulfillment = {
      filter_events = ["order_placed", "order_cancelled"]
    }
  }

  notify_timeout_seconds = 30
}

resource "aws_sqs_queue" "dlq" {
  for_each = local.consumers

  name                      = "${local.name}-${each.key}-dlq"
  message_retention_seconds = 1209600 # 14 days to investigate and redrive
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "main" {
  for_each = local.consumers

  name = "${local.name}-${each.key}"

  # AWS guidance: at least 6x the consumer Lambda timeout
  visibility_timeout_seconds = local.notify_timeout_seconds * 6
  message_retention_seconds  = 345600 # 4 days
  receive_wait_time_seconds  = 20     # long polling
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = 5
  })
}

data "aws_iam_policy_document" "queue" {
  for_each = local.consumers

  statement {
    sid       = "AllowOrderEventsTopic"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.main[each.key].arn]

    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_sns_topic.order_events.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "main" {
  for_each = local.consumers

  queue_url = aws_sqs_queue.main[each.key].id
  policy    = data.aws_iam_policy_document.queue[each.key].json
}

resource "aws_sns_topic_subscription" "queue" {
  for_each = local.consumers

  topic_arn            = aws_sns_topic.order_events.arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.main[each.key].arn
  raw_message_delivery = true

  # Publishers set a message attribute event_type; each queue only gets its events.
  filter_policy = jsonencode({
    event_type = each.value.filter_events
  })

  depends_on = [aws_sqs_queue_policy.main]
}

############################
# SES: sender identity for customer emails
# New SES accounts are in a sandbox (verified recipients only). Request
# production access in the console before real customers are emailed.
############################
resource "aws_sesv2_configuration_set" "main" {
  configuration_set_name = "${local.name}-transactional"

  delivery_options {
    tls_policy = "REQUIRE"
  }

  reputation_options {
    reputation_metrics_enabled = true
  }

  sending_options {
    sending_enabled = true
  }
}

resource "aws_sesv2_email_identity" "sender" {
  email_identity         = var.notification_from_email
  configuration_set_name = aws_sesv2_configuration_set.main.configuration_set_name
}

############################
# Notification Lambda: SQS -> dedupe -> SES email
############################
data "archive_file" "notify" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/notify"
  output_path = "${path.module}/.build/notify.zip"
}

resource "aws_cloudwatch_log_group" "notify" {
  name              = "/aws/lambda/${local.name}-notify"
  retention_in_days = var.log_retention_days
}

resource "aws_iam_role" "notify" {
  name = "${local.name}-notify-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "notify_logs" {
  role       = aws_iam_role.notify.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "notify_xray" {
  role       = aws_iam_role.notify.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXrayWriteOnlyAccess"
}

resource "aws_iam_role_policy" "notify" {
  name = "notify-runtime"
  role = aws_iam_role.notify.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = [aws_sqs_queue.main["notifications"].arn]
      },
      {
        Effect = "Allow"
        Action = ["ses:SendEmail"]
        Resource = [
          aws_sesv2_email_identity.sender.arn,
          aws_sesv2_configuration_set.main.arn
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:DeleteItem"]
        Resource = [aws_dynamodb_table.idempotency.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource = [aws_kms_key.main.arn]
      }
    ]
  })
}

resource "aws_lambda_function" "notify" {
  function_name = "${local.name}-notify"
  role          = aws_iam_role.notify.arn
  runtime       = "python3.13"
  handler       = "handler.lambda_handler"
  architectures = ["arm64"]
  timeout       = local.notify_timeout_seconds
  memory_size   = 256

  filename         = data.archive_file.notify.output_path
  source_code_hash = data.archive_file.notify.output_base64sha256

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      FROM_EMAIL        = var.notification_from_email
      CONFIG_SET        = aws_sesv2_configuration_set.main.configuration_set_name
      IDEMPOTENCY_TABLE = aws_dynamodb_table.idempotency.name
      LOG_LEVEL         = "INFO"
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.notify,
    aws_iam_role_policy_attachment.notify_logs
  ]
}

resource "aws_lambda_event_source_mapping" "notify" {
  event_source_arn                   = aws_sqs_queue.main["notifications"].arn
  function_name                      = aws_lambda_function.notify.arn
  batch_size                         = 10
  maximum_batching_window_in_seconds = 5

  # Only the failed messages in a batch are retried, not the whole batch.
  function_response_types = ["ReportBatchItemFailures"]

  scaling_config {
    maximum_concurrency = 20
  }

  depends_on = [aws_iam_role_policy.notify]
}
