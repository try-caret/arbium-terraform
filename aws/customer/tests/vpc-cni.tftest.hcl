# Offline, plan-only checks of the real EKS add-on configuration.
mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  # Unconfigured add-ons inherit this computed value; configured CNI must not.
  mock_resource "aws_eks_addon" {
    override_during = plan
    defaults        = { configuration_values = "provider-default" }
  }
}
mock_provider "tls" {}

variables {
  name_prefix                     = "test"
  environment                     = "test"
  cluster_version                 = "1.35"
  vpc_id                          = "vpc-00000001"
  subnet_ids                      = ["subnet-00000001", "subnet-00000002"]
  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true
  general_node_instance_types     = ["m6i.large"]
  general_node_min_size           = 1
  general_node_desired_size       = 1
  general_node_max_size           = 2
  gpu_node_instance_types         = ["g4dn.xlarge"]
  gpu_node_ami_type               = "AL2023_x86_64_NVIDIA"
  gpu_node_min_size               = 0
  gpu_node_desired_size           = 0
  gpu_node_max_size               = 1
  lake_node_instance_types        = ["r6i.2xlarge"]
  lake_node_min_size              = 0
  lake_node_desired_size          = 0
  lake_node_max_size              = 1
  tags                            = { application = "test" }
}

run "default_configuration_unchanged" {
  command = plan
  module { source = "./modules/eks" }
  assert {
    condition = aws_eks_addon.this["vpc-cni"].configuration_values == jsonencode({
      env = {
        WARM_IP_TARGET      = "2"
        MINIMUM_IP_TARGET   = "8"
        ADDITIONAL_ENI_TAGS = jsonencode(var.tags)
      }
    })
    error_message = "The default must preserve the complete existing CNI configuration."
  }
  assert {
    condition     = aws_eks_addon.this["coredns"].configuration_values == "provider-default" && aws_eks_addon.this["kube-proxy"].configuration_values == "provider-default"
    error_message = "IP reserve tuning must not configure other add-ons."
  }
}

run "larger_reserve_is_a_string_and_preserves_other_settings" {
  command = plan
  module { source = "./modules/eks" }
  variables { vpc_cni_warm_ip_target = 8 }
  assert {
    condition = aws_eks_addon.this["vpc-cni"].configuration_values == jsonencode({
      env = {
        WARM_IP_TARGET      = "8"
        MINIMUM_IP_TARGET   = "8"
        ADDITIONAL_ENI_TAGS = jsonencode(var.tags)
      }
    })
    error_message = "The override must be encoded as an environment string without changing the floor or tags."
  }
  assert {
    condition     = aws_eks_addon.this["coredns"].configuration_values == "provider-default" && aws_eks_addon.this["kube-proxy"].configuration_values == "provider-default"
    error_message = "The override must affect only the VPC CNI."
  }
}

run "reserve_override_preserves_network_policy_enforcement" {
  command = plan
  module { source = "./modules/eks" }
  variables {
    vpc_cni_warm_ip_target = 8
    enable_network_policy  = true
  }
  assert {
    condition = aws_eks_addon.this["vpc-cni"].configuration_values == jsonencode({
      env = {
        WARM_IP_TARGET      = "8"
        MINIMUM_IP_TARGET   = "8"
        ADDITIONAL_ENI_TAGS = jsonencode(var.tags)
      }
      enableNetworkPolicy = "true"
    })
    error_message = "Increasing the IP reserve must preserve network-policy enforcement."
  }
}

run "one_spare_address_is_valid" {
  command = plan
  module { source = "./modules/eks" }
  variables { vpc_cni_warm_ip_target = 1 }
  assert {
    condition     = jsondecode(aws_eks_addon.this["vpc-cni"].configuration_values).env.WARM_IP_TARGET == "1"
    error_message = "Any positive integer reserve must be supported, not only the default and the larger example."
  }
}

run "reject_zero" {
  command = plan
  module { source = "./modules/eks" }
  variables { vpc_cni_warm_ip_target = 0 }
  expect_failures = [var.vpc_cni_warm_ip_target]
}

run "reject_negative" {
  command = plan
  module { source = "./modules/eks" }
  variables { vpc_cni_warm_ip_target = -1 }
  expect_failures = [var.vpc_cni_warm_ip_target]
}

run "reject_fractional" {
  command = plan
  module { source = "./modules/eks" }
  variables { vpc_cni_warm_ip_target = 1.5 }
  expect_failures = [var.vpc_cni_warm_ip_target]
}

run "reject_null" {
  command = plan
  module { source = "./modules/eks" }
  variables { vpc_cni_warm_ip_target = null }
  expect_failures = [var.vpc_cni_warm_ip_target]
}
