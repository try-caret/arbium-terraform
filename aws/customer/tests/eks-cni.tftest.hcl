# Run with terraform test -filter=tests/eks-cni.tftest.hcl after backend-disabled init.
# Plans modules/eks alone with mocked providers: the VPC CNI settings with network policy off and on.
mock_provider "aws" {
  override_during = plan
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_resource "aws_eks_cluster" {
    defaults = {
      vpc_config            = { cluster_security_group_id = "sg-00000001" }
      certificate_authority = [{ data = "dGVzdA==" }]
      identity              = [{ oidc = [{ issuer = "https://oidc.eks.us-east-1.amazonaws.com/id/TEST" }] }]
    }
  }
}
mock_provider "tls" {
  mock_data "tls_certificate" {
    defaults = { certificates = [{ sha1_fingerprint = "0000000000000000000000000000000000000000" }] }
  }
}

variables {
  name_prefix                     = "arbium"
  environment                     = "test"
  cluster_version                 = "1.35"
  vpc_id                          = "vpc-00000001"
  subnet_ids                      = ["subnet-00000001", "subnet-00000002"]
  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true
  general_node_instance_types     = ["m6i.large"]
  general_node_min_size           = 1
  general_node_desired_size       = 2
  general_node_max_size           = 3
  gpu_node_instance_types         = ["g4dn.xlarge"]
  gpu_node_ami_type               = "AL2023_x86_64_NVIDIA"
  gpu_node_min_size               = 0
  gpu_node_desired_size           = 0
  gpu_node_max_size               = 1
  lake_node_instance_types        = ["r6i.2xlarge"]
  lake_node_min_size              = 0
  lake_node_desired_size          = 0
  lake_node_max_size              = 1
}

run "defaults_keep_the_existing_cni_settings" {
  command = plan
  module { source = "./modules/eks" }
  assert {
    condition = jsondecode(aws_eks_addon.this["vpc-cni"].configuration_values) == {
      env = { WARM_IP_TARGET = "2", MINIMUM_IP_TARGET = "8", ADDITIONAL_ENI_TAGS = "{}" }
    }
    error_message = "With network policy off, the CNI configuration is what clusters run today."
  }
}

run "network_policy_only_adds_enforcement" {
  command = plan
  module { source = "./modules/eks" }
  variables { enable_network_policy = true }
  assert {
    condition = jsondecode(aws_eks_addon.this["vpc-cni"].configuration_values) == {
      env                 = { WARM_IP_TARGET = "2", MINIMUM_IP_TARGET = "8", ADDITIONAL_ENI_TAGS = "{}" }
      enableNetworkPolicy = "true"
    }
    error_message = "Network policy enforcement is on and nothing else changes."
  }
}
