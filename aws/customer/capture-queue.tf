# Opt-in provisioning only. Enabling the edge/consumer remains a separate Helm rollout.
variable "enable_capture_queue" {
  type        = bool
  default     = false
  description = "Provision SQS capture ingestion, DLQ, workload IAM and native alerts."
  validation {
    condition     = !var.enable_capture_queue || (var.enable_capturelake && length(var.capture_queue_alarm_actions) > 0)
    error_message = "Capture queue requires enable_capturelake and at least one alarm notification target."
  }
}

variable "capture_queue_alarm_actions" {
  type        = list(string)
  default     = []
  description = "Existing SNS topic ARNs to notify for source freshness, outage age and DLQ alarms."
}

variable "capture_queue_sagemaker_endpoint_arn" {
  type        = string
  default     = ""
  description = "Optional exact SageMaker embedder endpoint ARN; empty when using the in-cluster HTTP embedder."
  validation {
    condition     = var.capture_queue_sagemaker_endpoint_arn == "" || can(regex("^arn:[^:]+:sagemaker:[^:]+:[0-9]+:endpoint/[^*]+$", var.capture_queue_sagemaker_endpoint_arn))
    error_message = "Use an exact SageMaker endpoint ARN, not a wildcard."
  }
}

resource "aws_sqs_queue" "captures_dlq" {
  count                     = var.enable_capture_queue ? 1 : 0
  name                      = "${var.name_prefix}-${var.environment}-captures-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
  tags                      = local.tags
}

resource "aws_sqs_queue" "captures" {
  count                      = var.enable_capture_queue ? 1 : 0
  name                       = "${var.name_prefix}-${var.environment}-captures"
  message_retention_seconds  = 1209600
  visibility_timeout_seconds = 120
  receive_wait_time_seconds  = 20
  max_message_size           = 1048576
  sqs_managed_sse_enabled    = true
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.captures_dlq[0].arn
    maxReceiveCount     = 5
  })
  tags = local.tags
}

resource "aws_sqs_queue_redrive_allow_policy" "captures" {
  count     = var.enable_capture_queue ? 1 : 0
  queue_url = aws_sqs_queue.captures_dlq[0].url
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.captures[0].arn]
  })
}

# Keep the existing edge-fns KSA; this role does not change its licensing identity.
resource "aws_iam_role" "capture_queue_publisher" {
  count = var.enable_capture_queue ? 1 : 0
  name  = "${var.name_prefix}-${var.environment}-capture-publisher"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = module.eks.oidc_provider_arn }
      Condition = { StringEquals = {
        "${local.oidc_issuer_host}:sub" = "system:serviceaccount:${var.arbium_namespace}:chaindb-edge-fns"
        "${local.oidc_issuer_host}:aud" = "sts.amazonaws.com"
      } }
    }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy" "capture_queue_publisher" {
  count = var.enable_capture_queue ? 1 : 0
  name  = "capture-queue-publish"
  role  = aws_iam_role.capture_queue_publisher[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      { Effect = "Allow", Action = ["sqs:SendMessage"], Resource = aws_sqs_queue.captures[0].arn }
      ], var.capture_queue_sagemaker_endpoint_arn == "" ? [] : [
      { Effect = "Allow", Action = ["sagemaker:InvokeEndpoint"], Resource = var.capture_queue_sagemaker_endpoint_arn }
    ])
  })
}

resource "aws_iam_role_policy" "capture_queue_consumer" {
  count = var.enable_capture_queue ? 1 : 0
  name  = "capture-queue-consume"
  role  = aws_iam_role.capturelake[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      { Effect = "Allow", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility"], Resource = aws_sqs_queue.captures[0].arn }
      ], var.capture_queue_sagemaker_endpoint_arn == "" ? [] : [
      { Effect = "Allow", Action = ["sagemaker:InvokeEndpoint"], Resource = var.capture_queue_sagemaker_endpoint_arn }
    ])
  })
}

# Depth and in-flight counts are native SQS metrics; alarms focus on age and any DLQ work.
resource "aws_cloudwatch_metric_alarm" "capture_queue" {
  for_each = var.enable_capture_queue ? {
    freshness = { dlq = false, metric = "ApproximateAgeOfOldestMessage", threshold = 60, periods = 5 }
    outage    = { dlq = false, metric = "ApproximateAgeOfOldestMessage", threshold = 86400, periods = 1 }
    dlq       = { dlq = true, metric = "ApproximateNumberOfMessagesVisible", threshold = 0, periods = 1 }
    dlq_age   = { dlq = true, metric = "ApproximateAgeOfOldestMessage", threshold = 3600, periods = 1 }
  } : {}
  alarm_name          = "${var.name_prefix}-${var.environment}-capture-queue-${each.key}"
  alarm_description   = "Capture queue ${each.key}: investigate before derive lookback or finite retention expires. Recovery: https://github.com/try-caret/arbium-terraform/blob/main/aws/customer/QUEUE_RECOVERY.md (also included in the pinned release)."
  namespace           = "AWS/SQS"
  metric_name         = each.value.metric
  dimensions          = { QueueName = each.value.dlq ? aws_sqs_queue.captures_dlq[0].name : aws_sqs_queue.captures[0].name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = each.value.periods
  threshold           = each.value.threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.capture_queue_alarm_actions
  ok_actions          = var.capture_queue_alarm_actions
  tags                = local.tags
}

output "capture_queue" {
  description = "Helm handoff: annotate existing edge/capturelake KSAs with these roles; merge env into both workloads. Flags remain off until separately approved."
  value = var.enable_capture_queue ? {
    queue_url          = aws_sqs_queue.captures[0].url
    dlq_url            = aws_sqs_queue.captures_dlq[0].url
    publisher_role_arn = aws_iam_role.capture_queue_publisher[0].arn
    consumer_role_arn  = aws_iam_role.capturelake[0].arn
  } : null
}
