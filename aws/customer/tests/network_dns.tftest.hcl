# No credentials, backend or cluster required. Mock every provider and plan only.
mock_provider "aws" {
  override_during = plan
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
  target = module.aurora
  outputs = {
    cluster_endpoint       = "test.cluster-example.us-east-1.rds.amazonaws.com"
    database_name          = "chaindb"
    master_user_secret_arn = "arn:aws:secretsmanager:us-east-1:111111111111:secret:rds!cluster-test-abcdef"
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

run "created_network_defaults_unchanged" {
  command = plan
  variables { existing_network = null }
  assert {
    condition     = length(module.network) == 1 && output.vpc_id == "vpc-aaaaaaaa" && length(output.private_subnet_ids) == 3 && length(output.public_subnet_ids) == 3 && length(module.network[0].private_route_table_ids) == 3
    error_message = "Default environments must still create their three-AZ network and preserve output shape."
  }
  assert {
    condition     = length(aws_route53_zone.ingress) == 0 && length(aws_route53_record.ingress_alias) == 0 && length(aws_route53_record.ingress_validation) == 0 && length(output.ingress_zone_name_servers) == 0
    error_message = "Existing environments must not gain DNS resources by default."
  }
}

run "supplied_network_skips_entire_module_even_with_creation_defaults" {
  command = plan
  assert {
    condition     = length(module.network) == 0 && output.vpc_id == "vpc-00000001" && tolist(output.private_subnet_ids) == var.existing_network.private_subnet_ids && tolist(output.public_subnet_ids) == var.existing_network.public_subnet_ids
    error_message = "Supplied networks must bypass all network resources, including endpoints, and return the validated IDs."
  }
}

run "reject_empty_private_subnets" {
  command = plan
  variables {
    existing_network = { vpc_id = "vpc-00000001", private_subnet_ids = [], public_subnet_ids = [] }
  }
  expect_failures = [var.existing_network]
}

run "reject_duplicate_private_subnets" {
  command = plan
  variables {
    existing_network = { vpc_id = "vpc-00000001", private_subnet_ids = ["subnet-00000001", "subnet-00000001"], public_subnet_ids = [] }
  }
  expect_failures = [var.existing_network]
}

run "reject_overlapping_subnet_lists" {
  command = plan
  variables {
    existing_network = { vpc_id = "vpc-00000001", private_subnet_ids = ["subnet-00000001", "subnet-00000002"], public_subnet_ids = ["subnet-00000001", "subnet-00000004"] }
  }
  expect_failures = [var.existing_network]
}

run "reject_wrong_vpc" {
  command = plan
  override_data {
    target = data.aws_subnet.existing["subnet-00000002"]
    values = { id = "subnet-00000002", vpc_id = "vpc-ffffffff", availability_zone = "us-east-1b" }
  }
  expect_failures = [data.aws_subnet.existing]
}

run "reject_one_private_az" {
  command = plan
  override_data {
    target = data.aws_subnet.existing["subnet-00000002"]
    values = { id = "subnet-00000002", vpc_id = "vpc-00000001", availability_zone = "us-east-1a" }
  }
  expect_failures = [data.aws_vpc.existing]
}

run "reject_missing_public_subnets" {
  command = plan
  variables {
    existing_network = { vpc_id = "vpc-00000001", private_subnet_ids = ["subnet-00000001", "subnet-00000002"] }
  }
  expect_failures = [data.aws_vpc.existing]
}

run "reject_worker_az_outside_alb_coverage" {
  command = plan
  override_data {
    target = data.aws_subnet.existing["subnet-00000002"]
    values = { id = "subnet-00000002", vpc_id = "vpc-00000001", availability_zone = "us-east-1c" }
  }
  expect_failures = [data.aws_vpc.existing]
}

run "reject_disabled_vpc_dns" {
  command = plan
  override_data {
    target = data.aws_vpc.existing[0]
    values = { id = "vpc-00000001", enable_dns_support = false, enable_dns_hostnames = true }
  }
  expect_failures = [data.aws_vpc.existing]
}

run "internal_ingress_needs_no_public_subnets" {
  command = plan
  variables {
    ingress_scheme   = "internal"
    existing_network = { vpc_id = "vpc-00000001", private_subnet_ids = ["subnet-00000001", "subnet-00000002"] }
  }
  assert {
    condition     = length(module.network) == 0 && length(output.public_subnet_ids) == 0
    error_message = "Internal ingress must accept private-only customer networking."
  }
}

run "dns_foundation_does_not_require_delegation_or_alb" {
  command = plan
  variables {
    create_public_hosted_zone  = true
    create_ingress_certificate = true
    ingress_domain_name        = "service.example.com"
  }
  assert {
    condition     = aws_route53_zone.ingress[0].name == "service.example.com" && !aws_route53_zone.ingress[0].force_destroy && length(output.ingress_zone_name_servers) == 4 && length(aws_route53_record.ingress_alias) == 0
    error_message = "Foundation must create the zone and report assigned nameservers without waiting for the application ALB."
  }
  assert {
    condition     = aws_route53_record.ingress_validation[0].zone_id == "ZNEWZONE" && aws_route53_record.ingress_validation[0].name == "_validation.service.example.com" && aws_route53_record.ingress_validation[0].type == "CNAME"
    error_message = "ACM validation must be recorded in the new zone."
  }
}

run "post_helm_alias_uses_the_albs_canonical_zone" {
  command = plan
  variables {
    create_public_hosted_zone  = true
    create_ingress_certificate = true
    ingress_domain_name        = "service.example.com"
    ingress_alb                = { dns_name = "test.us-east-1.elb.amazonaws.com", zone_id = "ZALBZONE" }
  }
  assert {
    condition     = aws_route53_record.ingress_alias[0].zone_id == "ZNEWZONE" && one(aws_route53_record.ingress_alias[0].alias).zone_id == "ZALBZONE" && one(aws_route53_record.ingress_alias[0].alias).name == "test.us-east-1.elb.amazonaws.com"
    error_message = "Alias destination must use the ALB zone ID, not the application's zone ID."
  }
}

run "reject_zone_without_certificate" {
  command = plan
  variables {
    create_public_hosted_zone = true
    ingress_domain_name       = "service.example.com"
  }
  expect_failures = [aws_route53_zone.ingress]
}

run "accept_acms_canonical_domain_case" {
  command = plan
  variables {
    create_public_hosted_zone  = true
    create_ingress_certificate = true
    ingress_domain_name        = "Service.Example.Com"
  }
  assert {
    condition     = aws_route53_record.ingress_validation[0].name == "_validation.service.example.com"
    error_message = "DNS validation must tolerate ACM normalizing the requested domain's case."
  }
}

run "reject_duplicate_public_az" {
  command = plan
  override_data {
    target = data.aws_subnet.existing["subnet-00000004"]
    values = { id = "subnet-00000004", vpc_id = "vpc-00000001", availability_zone = "us-east-1a" }
  }
  expect_failures = [data.aws_vpc.existing]
}

run "reject_disabled_vpc_hostnames" {
  command = plan
  override_data {
    target = data.aws_vpc.existing[0]
    values = { id = "vpc-00000001", enable_dns_support = true, enable_dns_hostnames = false }
  }
  expect_failures = [data.aws_vpc.existing]
}

run "reject_alias_into_unmanaged_zone" {
  command = plan
  variables {
    ingress_alb = { dns_name = "test.us-east-1.elb.amazonaws.com", zone_id = "ZALBZONE" }
  }
  expect_failures = [aws_route53_record.ingress_alias]
}
