# Run with terraform test -filter=tests/capture-queue.tftest.hcl after backend-disabled init.
# All providers are mocked; these targeted plans never read live state or contact AWS/Kubernetes.
mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}
mock_provider "tls" {}
mock_provider "kubernetes" {}
mock_provider "helm" {}
override_module {
  target = module.eks
  outputs = {
    oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/TEST"
    oidc_issuer_url   = "https://oidc.eks.us-east-1.amazonaws.com/id/TEST"
    cluster_name      = "test-cluster"
    cluster_endpoint  = "https://example.invalid"
    cluster_ca_data   = "dGVzdA=="
  }
}
variables {
  enable_capturelake          = true
  enable_capture_queue        = true
  capture_queue_alarm_actions = ["arn:aws:sns:us-east-1:123456789012:test-alerts"]
  availability_zones          = ["us-east-1a", "us-east-1b", "us-east-1c"]
}
run "queue_retention_iam_and_alarms" {
  command = plan
  plan_options {
    target = [aws_sqs_queue.captures, aws_sqs_queue.captures_dlq, aws_sqs_queue_redrive_allow_policy.captures, aws_iam_role_policy.capture_queue_publisher, aws_iam_role_policy.capture_queue_consumer, aws_cloudwatch_metric_alarm.capture_queue]
  }
  assert {
    condition     = aws_sqs_queue.captures[0].message_retention_seconds == 1209600 && aws_sqs_queue.captures_dlq[0].message_retention_seconds == 1209600 && aws_sqs_queue.captures[0].visibility_timeout_seconds == 120 && aws_sqs_queue.captures[0].max_message_size == 1048576
    error_message = "Source/DLQ retention, lease or encoded message limit changed."
  }
  assert {
    condition     = aws_sqs_queue.captures[0].sqs_managed_sse_enabled && aws_sqs_queue.captures_dlq[0].sqs_managed_sse_enabled
    error_message = "Both queues must encrypt captures at rest."
  }
  assert {
    condition     = length(aws_cloudwatch_metric_alarm.capture_queue) == 4 && aws_cloudwatch_metric_alarm.capture_queue["freshness"].threshold == 60
    error_message = "Native freshness, outage and DLQ alerts are required."
  }
  assert {
    condition     = alltrue([for alarm in aws_cloudwatch_metric_alarm.capture_queue : strcontains(alarm.alarm_description, "https://github.com/try-caret/arbium-terraform/blob/main/aws/customer/QUEUE_RECOVERY.md")])
    error_message = "Every alarm must link to the customer recovery document shipped in the public mirror."
  }
}
# An install that holds a queue commit window raises the freshness threshold and lowers its periods. Both default to
# 60 s and 5 periods for every other install, the other three alarms never move, and out-of-range values are refused.
run "freshness_defaults_are_60s_and_5_periods" {
  command = plan
  plan_options { target = [aws_cloudwatch_metric_alarm.capture_queue] }
  assert {
    condition     = aws_cloudwatch_metric_alarm.capture_queue["freshness"].threshold == 60 && aws_cloudwatch_metric_alarm.capture_queue["freshness"].evaluation_periods == 5
    error_message = "The freshness alarm must stay at 60 s and 5 periods unless the variables are set."
  }
}
run "freshness_threshold_and_periods_are_configurable" {
  command = plan
  variables {
    capture_queue_freshness_threshold_seconds  = 300
    capture_queue_freshness_evaluation_periods = 3
  }
  plan_options { target = [aws_cloudwatch_metric_alarm.capture_queue] }
  assert {
    condition     = aws_cloudwatch_metric_alarm.capture_queue["freshness"].threshold == 300 && aws_cloudwatch_metric_alarm.capture_queue["freshness"].evaluation_periods == 3
    error_message = "The freshness threshold and periods must follow the variables."
  }
  assert {
    condition     = aws_cloudwatch_metric_alarm.capture_queue["outage"].threshold == 86400 && aws_cloudwatch_metric_alarm.capture_queue["outage"].evaluation_periods == 1 && aws_cloudwatch_metric_alarm.capture_queue["dlq"].threshold == 0 && aws_cloudwatch_metric_alarm.capture_queue["dlq_age"].threshold == 3600
    error_message = "Only the freshness alarm may follow the variables."
  }
}
run "reject_freshness_below_the_60s_target" {
  command = plan
  variables { capture_queue_freshness_threshold_seconds = 59 }
  plan_options { target = [aws_cloudwatch_metric_alarm.capture_queue] }
  expect_failures = [var.capture_queue_freshness_threshold_seconds]
}
run "reject_freshness_above_the_sanity_cap" {
  command = plan
  variables { capture_queue_freshness_threshold_seconds = 601 }
  plan_options { target = [aws_cloudwatch_metric_alarm.capture_queue] }
  expect_failures = [var.capture_queue_freshness_threshold_seconds]
}
run "reject_freshness_periods_out_of_range" {
  command = plan
  variables { capture_queue_freshness_evaluation_periods = 0 }
  plan_options { target = [aws_cloudwatch_metric_alarm.capture_queue] }
  expect_failures = [var.capture_queue_freshness_evaluation_periods]
}
run "reject_freshness_periods_above_5" {
  command = plan
  variables { capture_queue_freshness_evaluation_periods = 6 }
  plan_options { target = [aws_cloudwatch_metric_alarm.capture_queue] }
  expect_failures = [var.capture_queue_freshness_evaluation_periods]
}
run "reject_freshness_periods_not_whole" {
  command = plan
  variables { capture_queue_freshness_evaluation_periods = 2.5 }
  plan_options { target = [aws_cloudwatch_metric_alarm.capture_queue] }
  expect_failures = [var.capture_queue_freshness_evaluation_periods]
}
# The alarm pages at about threshold + periods x 60 s, which has to stay within the 600 s seal of an episode.
run "reject_freshness_page_time_past_600s" {
  command = plan
  variables {
    capture_queue_freshness_threshold_seconds  = 600
    capture_queue_freshness_evaluation_periods = 5
  }
  plan_options { target = [aws_cloudwatch_metric_alarm.capture_queue] }
  expect_failures = [var.capture_queue_freshness_evaluation_periods]
}
run "reject_freshness_page_time_at_601s" {
  command = plan
  variables {
    capture_queue_freshness_threshold_seconds  = 301
    capture_queue_freshness_evaluation_periods = 5
  }
  plan_options { target = [aws_cloudwatch_metric_alarm.capture_queue] }
  expect_failures = [var.capture_queue_freshness_evaluation_periods]
}
run "accept_freshness_page_time_at_exactly_600s" {
  command = plan
  variables {
    capture_queue_freshness_threshold_seconds  = 300
    capture_queue_freshness_evaluation_periods = 5
  }
  plan_options { target = [aws_cloudwatch_metric_alarm.capture_queue] }
  assert {
    condition     = aws_cloudwatch_metric_alarm.capture_queue["freshness"].threshold == 300 && aws_cloudwatch_metric_alarm.capture_queue["freshness"].evaluation_periods == 5
    error_message = "A page time of exactly 600 s must be accepted."
  }
}
run "reject_unrouted_alerts" {
  command = plan
  variables { capture_queue_alarm_actions = [] }
  plan_options { target = [aws_sqs_queue.captures] }
  expect_failures = [var.enable_capture_queue]
}
run "disabled_by_default" {
  command = plan
  variables { enable_capture_queue = false }
  plan_options {
    target = [aws_sqs_queue.captures, aws_sqs_queue.captures_dlq, aws_iam_role.capture_queue_publisher, aws_cloudwatch_metric_alarm.capture_queue]
  }
  assert {
    condition     = length(aws_sqs_queue.captures) == 0 && length(aws_sqs_queue.captures_dlq) == 0 && length(aws_iam_role.capture_queue_publisher) == 0 && length(aws_cloudwatch_metric_alarm.capture_queue) == 0
    error_message = "Disabled provisioning must not create queues, publisher roles or alerts."
  }
}
