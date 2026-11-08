# Root wiring for the Aurora Performance Insights variables: plans the root with the real aurora module
# (every other module overridden as in network_dns.tftest.hcl) and reads the module's output.
# Run with terraform test -filter=tests/aurora-performance-insights-root.tftest.hcl after backend-disabled init.
mock_provider "aws" {
  override_during = plan
  mock_resource "aws_rds_cluster_instance" {
    defaults = { performance_insights_retention_period = 999 }
  }
  mock_resource "aws_rds_cluster" {
    defaults = { master_user_secret = [{ secret_arn = "arn:aws:secretsmanager:us-east-1:111111111111:secret:test" }] }
  }
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-east-1a", "us-east-1b", "us-east-1c"] }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111111111111" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_vpc" {
    defaults = { enable_dns_support = true, enable_dns_hostnames = true }
  }
  mock_resource "aws_vpc" {
    defaults = { id = "vpc-aaaaaaaa" }
  }
  mock_resource "aws_acm_certificate" {
    defaults = {
      domain_validation_options = [{
        domain_name           = "service.example.com"
        resource_record_name  = "_validation.service.example.com"
        resource_record_type  = "CNAME"
        resource_record_value = "_validation.acm-validations.aws."
      }]
    }
  }
  mock_resource "aws_route53_zone" {
    defaults = { zone_id = "ZNEWZONE", name_servers = ["ns-1.example.net", "ns-2.example.net", "ns-3.example.net", "ns-4.example.net"] }
  }
}
mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "tls" {}
mock_provider "null" {}

# These modules are unchanged; test the root wiring without their unrelated
# computed credentials/connection data. Never execute secret-purge provisioners.
override_module {
  target = module.eks
  outputs = {
    cluster_name              = "test"
    cluster_endpoint          = "https://test.example.com"
    cluster_ca_certificate    = "dGVzdA=="
    oidc_issuer_url           = "https://oidc.eks.us-east-1.amazonaws.com/id/test"
    oidc_provider_arn         = "arn:aws:iam::111111111111:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/test"
    cluster_security_group_id = "sg-00000001"
    node_security_group_id    = "sg-00000001"
  }
}
override_module {
  target  = module.secrets
  outputs = { secret_arns = {} }
}
override_resource {
  target = null_resource.purge_pending_secrets
}
override_data {
  target = data.aws_subnet.existing["subnet-00000001"]
  values = { id = "subnet-00000001", vpc_id = "vpc-00000001", availability_zone = "us-east-1a" }
}
override_data {
  target = data.aws_subnet.existing["subnet-00000002"]
  values = { id = "subnet-00000002", vpc_id = "vpc-00000001", availability_zone = "us-east-1b" }
}
override_data {
  target = data.aws_subnet.existing["subnet-00000003"]
  values = { id = "subnet-00000003", vpc_id = "vpc-00000001", availability_zone = "us-east-1a" }
}
override_data {
  target = data.aws_subnet.existing["subnet-00000004"]
  values = { id = "subnet-00000004", vpc_id = "vpc-00000001", availability_zone = "us-east-1b" }
}

variables {
  existing_network = {
    vpc_id             = "vpc-00000001"
    private_subnet_ids = ["subnet-00000001", "subnet-00000002"]
    public_subnet_ids  = ["subnet-00000003", "subnet-00000004"]
  }
}

run "root_default_turns_performance_insights_on" {
  command = plan
  assert {
    condition     = module.aurora.performance_insights_enabled == true && module.aurora.performance_insights_retention_period == 7
    error_message = "The root must leave Performance Insights on with 7 days by default."
  }
}
run "root_variable_reaches_the_module" {
  command = plan
  variables {
    aurora_performance_insights_enabled          = false
    aurora_performance_insights_retention_period = 93
  }
  assert {
    condition     = module.aurora.performance_insights_enabled == false
    error_message = "aurora_performance_insights_enabled must be passed from the root to the aurora module."
  }
}
run "root_retention_reaches_the_module" {
  command = plan
  variables { aurora_performance_insights_retention_period = 93 }
  assert {
    condition     = module.aurora.performance_insights_retention_period == 93
    error_message = "aurora_performance_insights_retention_period must be passed from the root to the aurora module."
  }
}
