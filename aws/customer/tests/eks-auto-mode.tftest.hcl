# Run with terraform test -filter=tests/eks-auto-mode.tftest.hcl after backend-disabled init.
# Plans modules/eks alone with mocked providers: EKS Auto Mode off, and on for Nitro sandbox nodes.
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

run "auto_mode_is_off_by_default" {
  command = plan
  module { source = "./modules/eks" }
  assert {
    condition     = length(aws_eks_cluster.this.compute_config) == 0 && length(aws_eks_cluster.this.storage_config) == 0 && length(aws_iam_role.auto_nodes) == 0 && length(aws_iam_role_policy.auto_mode_tags) == 0
    error_message = "Existing clusters see no Auto Mode change."
  }
  assert {
    condition     = jsondecode(aws_iam_role.cluster.assume_role_policy).Statement[0].Action == ["sts:AssumeRole"] && length(aws_iam_role_policy_attachment.cluster) == 1
    error_message = "The cluster role is unchanged."
  }
}

run "auto_mode_turns_on_with_its_roles_and_no_node_pools" {
  command = plan
  module { source = "./modules/eks" }
  variables {
    cluster_version  = "1.36"
    enable_auto_mode = true
  }
  assert {
    condition     = aws_eks_cluster.this.compute_config[0].enabled && aws_eks_cluster.this.storage_config[0].block_storage[0].enabled && aws_eks_cluster.this.kubernetes_network_config[0].elastic_load_balancing[0].enabled
    error_message = "AWS turns Auto Mode's compute, storage and load balancing on together."
  }
  assert {
    condition     = aws_eks_cluster.this.compute_config[0].node_role_arn == null
    error_message = "No built-in node pools: Auto Mode launches nodes only for NodePools added to the cluster."
  }
  assert {
    condition     = length(aws_iam_role_policy_attachment.cluster) == 5 && aws_eks_access_entry.auto_nodes[0].type == "EC2" && endswith(aws_eks_access_policy_association.auto_nodes[0].policy_arn, "AmazonEKSAutoNodePolicy")
    error_message = "The cluster role gets Auto Mode's policies and its nodes an access entry."
  }
  assert {
    condition     = [for st in jsondecode(aws_iam_role_policy.auto_mode_tags[0].policy).Statement : st.Condition.StringEquals["aws:RequestTag/eks:eks-cluster-name"] if can(st.Condition.StringEquals["aws:RequestTag/eks:eks-cluster-name"])] == ["$${aws:PrincipalTag/eks:eks-cluster-name}", "$${aws:PrincipalTag/eks:eks-cluster-name}", "$${aws:PrincipalTag/eks:eks-cluster-name}"]
    error_message = "Our tags on what Auto Mode launches are allowed only for this cluster's own launches."
  }
}
