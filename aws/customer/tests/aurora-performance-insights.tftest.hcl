# Run with terraform test -filter=tests/aurora-performance-insights.tftest.hcl after backend-disabled init.
# Plans the Aurora module on its own with a mocked AWS provider; nothing reads live state or contacts AWS.
mock_provider "aws" {
  # The retention argument is computed, so a plan cannot show "left unset". An unset one gets 999 from
  # the mock: seeing 999 means the module sent nothing, seeing 7 means it sent 7.
  mock_resource "aws_rds_cluster_instance" {
    defaults = { performance_insights_retention_period = 999 }
  }
  mock_resource "aws_rds_cluster" {
    defaults = { master_user_secret = [{ secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:test" }] }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}
variables {
  name_prefix                = "test"
  environment                = "qa"
  vpc_id                     = "vpc-0123456789abcdef0"
  subnet_ids                 = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
  eks_node_security_group_id = "sg-0123456789abcdef0"
}
run "on_by_default_with_seven_days" {
  command = plan
  module { source = "./modules/aurora" }
  assert {
    condition     = aws_rds_cluster_instance.this[0].performance_insights_enabled == true && aws_rds_cluster_instance.this[0].performance_insights_retention_period == 7
    error_message = "Aurora instances must have Performance Insights on with the free 7-day retention by default."
  }
}
run "off_has_no_retention" {
  command = apply
  module { source = "./modules/aurora" }
  variables { performance_insights_enabled = false }
  assert {
    condition     = aws_rds_cluster_instance.this[0].performance_insights_enabled == false && aws_rds_cluster_instance.this[0].performance_insights_retention_period == 999
    error_message = "Turning Performance Insights off must not send a retention period."
  }
}
run "longer_retention_is_passed_through" {
  command = plan
  module { source = "./modules/aurora" }
  variables { performance_insights_retention_period = 93 }
  assert {
    condition     = aws_rds_cluster_instance.this[0].performance_insights_retention_period == 93
    error_message = "A valid longer retention must reach the instance."
  }
}
run "reject_retention_aws_does_not_accept" {
  command = plan
  module { source = "./modules/aurora" }
  variables { performance_insights_retention_period = 30 }
  expect_failures = [var.performance_insights_retention_period]
}
run "accept_731_days" {
  command = plan
  module { source = "./modules/aurora" }
  variables { performance_insights_retention_period = 731 }
  assert {
    condition     = aws_rds_cluster_instance.this[0].performance_insights_retention_period == 731
    error_message = "731 days is accepted by AWS and must reach the instance."
  }
}
run "reject_38_days" {
  command = plan
  module { source = "./modules/aurora" }
  variables { performance_insights_retention_period = 38 }
  expect_failures = [var.performance_insights_retention_period]
}
run "reject_zero_days" {
  command = plan
  module { source = "./modules/aurora" }
  variables { performance_insights_retention_period = 0 }
  expect_failures = [var.performance_insights_retention_period]
}
