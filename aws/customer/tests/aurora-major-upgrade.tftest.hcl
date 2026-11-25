# Run with terraform test -filter=tests/aurora-major-upgrade.tftest.hcl after backend-disabled init.
# Plans the Aurora module on its own with a mocked AWS provider; nothing reads live state or contacts AWS.
#
# The parameter group's name, family and description follow the engine's major. For a cluster that stays on
# 16 they must equal what the module created before the family was derived (all three are ForceNew, so any
# drift would replace a group the live cluster is using). The 17 values are what a 16 -> 17 upgrade switches to.
mock_provider "aws" {
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
run "pg16_keeps_the_names_it_always_had" {
  command = plan
  module { source = "./modules/aurora" }
  variables { engine_version = "16.13" }
  assert {
    condition     = aws_rds_cluster_parameter_group.this.name == "test-qa-aurora-pg16" && aws_rds_cluster_parameter_group.this.family == "aurora-postgresql16" && aws_rds_cluster_parameter_group.this.description == "Arbium Aurora PostgreSQL 16 cluster parameters"
    error_message = "A cluster on 16.x must keep the pg16 parameter group name, family and description byte for byte."
  }
  assert {
    condition     = toset([for p in aws_rds_cluster_parameter_group.this.parameter : p.name]) == toset(["shared_preload_libraries"])
    error_message = "The pg16 group must keep exactly its one parameter, so 16.x clusters plan no change."
  }
}
run "pg17_gets_its_own_group" {
  command = plan
  module { source = "./modules/aurora" }
  variables { engine_version = "17.11" }
  assert {
    condition     = aws_rds_cluster_parameter_group.this.name == "test-qa-aurora-pg17" && aws_rds_cluster_parameter_group.this.family == "aurora-postgresql17" && aws_rds_cluster_parameter_group.this.description == "Arbium Aurora PostgreSQL 17 cluster parameters"
    error_message = "A cluster on 17.x must use a pg17 parameter group with a different name from the pg16 one."
  }
  assert {
    condition     = one([for p in aws_rds_cluster_parameter_group.this.parameter : p if p.name == "rds.force_ssl"]).value == "0" && one([for p in aws_rds_cluster_parameter_group.this.parameter : p if p.name == "rds.force_ssl"]).apply_method == "immediate"
    error_message = "The pg17 group must set rds.force_ssl=0 (Aurora 17 defaults it to 1, which locks out clients without TLS)."
  }
  assert {
    condition     = one([for p in aws_rds_cluster_parameter_group.this.parameter : p if p.name == "shared_preload_libraries"]).value == "pg_stat_statements"
    error_message = "The pg17 group must still preload pg_stat_statements."
  }
}
run "new_installs_default_to_17" {
  command = plan
  module { source = "./modules/aurora" }
  assert {
    condition     = aws_rds_cluster.this.engine_version == "17.11" && aws_rds_cluster_parameter_group.this.family == "aurora-postgresql17"
    error_message = "With no engine_version set the module installs Aurora PostgreSQL 17.11 with the 17 family."
  }
}
run "major_upgrade_is_off_by_default" {
  command = plan
  module { source = "./modules/aurora" }
  variables { engine_version = "16.13" }
  assert {
    condition     = aws_rds_cluster.this.allow_major_version_upgrade == null
    error_message = "With the flag off the module must leave allow_major_version_upgrade unset (null, as existing state holds), not write an explicit false."
  }
}
run "major_upgrade_flag_reaches_the_cluster" {
  command = plan
  module { source = "./modules/aurora" }
  variables {
    engine_version              = "17.11"
    allow_major_version_upgrade = true
  }
  assert {
    condition     = aws_rds_cluster.this.allow_major_version_upgrade == true
    error_message = "allow_major_version_upgrade must reach aws_rds_cluster."
  }
}
run "engine_version_must_start_with_major_minor" {
  command = plan
  module { source = "./modules/aurora" }
  variables { engine_version = "latest" }
  expect_failures = [var.engine_version]
}
