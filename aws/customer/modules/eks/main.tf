locals {
  cluster_name = "${var.name_prefix}-${var.environment}"
}

data "aws_partition" "current" {}

resource "aws_iam_role" "cluster" {
  name = "${local.cluster_name}-eks-cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      # Auto Mode tags what it launches with the cluster's session. IAM reads ["x"] as "x": no diff.
      Action = concat(["sts:AssumeRole"], var.enable_auto_mode ? ["sts:TagSession"] : [])
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  for_each = toset(concat(
    ["arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy"],
    var.enable_auto_mode ? [
      for p in ["AmazonEKSComputePolicy", "AmazonEKSBlockStoragePolicy", "AmazonEKSLoadBalancingPolicy", "AmazonEKSNetworkingPolicy"] :
      "arn:${data.aws_partition.current.partition}:iam::aws:policy/${p}"
    ] : [],
  ))

  role       = aws_iam_role.cluster.name
  policy_arn = each.value
}

resource "aws_eks_cluster" "this" {
  name     = local.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.cluster_version

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_public_access  = var.cluster_endpoint_public_access
    endpoint_private_access = var.cluster_endpoint_private_access
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  # EKS Auto Mode, for Nitro sandbox nodes only: no built-in node pools, so it launches a node only
  # for a NodePool someone adds (the agent platform's sandboxes) and nothing else moves. AWS turns
  # its compute, block storage and load balancing on together; the existing load balancer
  # controller and EBS driver keep their own classes.
  dynamic "compute_config" {
    for_each = var.enable_auto_mode ? [1] : []
    content {
      enabled = true
    }
  }
  dynamic "kubernetes_network_config" {
    for_each = var.enable_auto_mode ? [1] : []
    content {
      elastic_load_balancing {
        enabled = true
      }
    }
  }
  dynamic "storage_config" {
    for_each = var.enable_auto_mode ? [1] : []
    content {
      block_storage {
        enabled = true
      }
    }
  }

  tags = var.tags

  depends_on = [aws_iam_role_policy_attachment.cluster]
}

resource "aws_iam_role" "nodes" {
  name = "${local.cluster_name}-eks-nodes"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "nodes" {
  for_each = toset([
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ])

  role       = aws_iam_role.nodes.name
  policy_arn = each.value
}

# AWS's managed Auto Mode policies refuse tags of our own on what Auto Mode launches, and an install
# whose account requires tags at launch needs them: AWS's custom-tag policy, its EC2 statements only
# (docs.aws.amazon.com/eks/latest/userguide/auto-cluster-iam-role.html#tag-prop).
resource "aws_iam_role_policy" "auto_mode_tags" {
  count = var.enable_auto_mode ? 1 : 0
  name  = "auto-mode-tags"
  role  = aws_iam_role.cluster.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Compute"
        Effect   = "Allow"
        Action   = ["ec2:CreateFleet", "ec2:RunInstances", "ec2:CreateLaunchTemplate"]
        Resource = "*"
        Condition = {
          StringEquals = { "aws:RequestTag/eks:eks-cluster-name" = "$${aws:PrincipalTag/eks:eks-cluster-name}" }
          StringLike   = { "aws:RequestTag/eks:kubernetes-node-class-name" = "*", "aws:RequestTag/eks:kubernetes-node-pool-name" = "*" }
        }
      },
      {
        Sid       = "Storage"
        Effect    = "Allow"
        Action    = ["ec2:CreateVolume", "ec2:CreateSnapshot"]
        Resource  = ["arn:${data.aws_partition.current.partition}:ec2:*:*:volume/*", "arn:${data.aws_partition.current.partition}:ec2:*:*:snapshot/*"]
        Condition = { StringEquals = { "aws:RequestTag/eks:eks-cluster-name" = "$${aws:PrincipalTag/eks:eks-cluster-name}" } }
      },
      {
        Sid      = "Networking"
        Effect   = "Allow"
        Action   = "ec2:CreateNetworkInterface"
        Resource = "*"
        Condition = {
          StringEquals = { "aws:RequestTag/eks:eks-cluster-name" = "$${aws:PrincipalTag/eks:eks-cluster-name}" }
          StringLike   = { "aws:RequestTag/eks:kubernetes-cni-node-name" = "*" }
        }
      },
      {
        Sid       = "ModifyTagsOnClusterResources"
        Effect    = "Allow"
        Action    = ["ec2:CreateTags", "ec2:DeleteTags"]
        Resource  = "*"
        Condition = { StringEquals = { "aws:ResourceTag/eks:eks-cluster-name" = "$${aws:PrincipalTag/eks:eks-cluster-name}" } }
      },
    ]
  })
}

# The role Auto Mode nodes run as. With no built-in node pools EKS makes no access entry for it.
resource "aws_iam_role" "auto_nodes" {
  count = var.enable_auto_mode ? 1 : 0
  name  = "${local.cluster_name}-eks-auto-nodes"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "auto_nodes" {
  for_each = toset(var.enable_auto_mode ? [
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodeMinimalPolicy",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
  ] : [])

  role       = aws_iam_role.auto_nodes[0].name
  policy_arn = each.value
}

resource "aws_eks_access_entry" "auto_nodes" {
  count         = var.enable_auto_mode ? 1 : 0
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.auto_nodes[0].arn
  type          = "EC2"
  tags          = var.tags
}

resource "aws_eks_access_policy_association" "auto_nodes" {
  count         = var.enable_auto_mode ? 1 : 0
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_eks_access_entry.auto_nodes[0].principal_arn
  policy_arn    = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSAutoNodePolicy"
  access_scope {
    type = "cluster"
  }
}

# Managed node groups do NOT propagate node-group tags to the launched EC2
# instances, their EBS volumes, or their primary ENIs. A launch template with
# tag_specifications is the only way to tag those at launch. No image_id/
# instance_type here, so EKS still selects the AMI from ami_type and uses the
# node group's instance_types. Gated because attaching it replaces node groups.
resource "aws_launch_template" "node" {
  count       = var.enable_node_launch_template ? 1 : 0
  name_prefix = "${local.cluster_name}-node-"

  tag_specifications {
    resource_type = "instance"
    tags          = var.tags
  }
  tag_specifications {
    resource_type = "volume"
    tags          = var.tags
  }
  tag_specifications {
    resource_type = "network-interface"
    tags          = var.tags
  }

  tags = var.tags
}

resource "aws_eks_node_group" "general" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "general"
  node_role_arn   = aws_iam_role.nodes.arn
  subnet_ids      = var.subnet_ids
  instance_types  = var.general_node_instance_types
  capacity_type   = "ON_DEMAND"

  dynamic "launch_template" {
    for_each = var.enable_node_launch_template ? [1] : []
    content {
      id      = aws_launch_template.node[0].id
      version = aws_launch_template.node[0].latest_version
    }
  }

  scaling_config {
    min_size     = var.general_node_min_size
    desired_size = var.general_node_desired_size
    max_size     = var.general_node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    workload = "general"
  }

  tags = merge(var.tags, {
    Name = "${local.cluster_name}-general"
  })

  depends_on = [aws_iam_role_policy_attachment.nodes]
}

resource "aws_eks_node_group" "gpu" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "embedder-gpu"
  node_role_arn   = aws_iam_role.nodes.arn
  subnet_ids      = var.subnet_ids
  instance_types  = var.gpu_node_instance_types
  ami_type        = var.gpu_node_ami_type
  capacity_type   = "ON_DEMAND"

  dynamic "launch_template" {
    for_each = var.enable_node_launch_template ? [1] : []
    content {
      id      = aws_launch_template.node[0].id
      version = aws_launch_template.node[0].latest_version
    }
  }

  scaling_config {
    min_size     = var.gpu_node_min_size
    desired_size = var.gpu_node_desired_size
    max_size     = var.gpu_node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    workload                 = "embedder"
    "nvidia.com/gpu.present" = "true"
  }

  taint {
    key    = "workload"
    value  = "embedder"
    effect = "NO_SCHEDULE"
  }

  tags = merge(var.tags, {
    Name = "${local.cluster_name}-embedder-gpu"
  })

  depends_on = [aws_iam_role_policy_attachment.nodes]
}

# A node of its own for the CaptureLake writer, where a deployment asks for one. ADDITIVE: desired 0
# renders no node group at all, so an existing cluster sees no plan at all until it opts in, and the
# general group is never resized or retyped (changing its instance type replaces every node on it).
#
# The writer is the one pod sized by how much data it re-merges rather than by how many requests it
# serves. The compact rewrites each person's whole day into one file, so its peak grows through the
# day AND with the fleet: measured on arbium-prod, 1.76 GB at 18:45 UTC on 2026-09-17 and 4.05 GB by
# 07:45 the next morning with HALF the people. Sharing an m6i.large (~7.1Gi allocatable) caps the
# writer near 6Gi, and 6Gi is not enough room for the fleet to keep growing.
#
# Memory-optimised by default (r6i.2xlarge: 64 GiB, 8 vCPU) because that is the axis that binds —
# CPU throttling on the writer has been ~zero throughout. An m6i.4xlarge is the same memory for
# 52% more money and twice the cores nobody is using.
#
# Tainted, not merely labelled: an unrelated pod scheduled here would put the ceiling back, which is
# the whole problem this removes. The chart's capturelake nodeSelector + tolerations are what opt
# the writer (and its Argo workflow pods for maintenance) in.
resource "aws_eks_node_group" "lake" {
  count = var.lake_node_desired_size > 0 ? 1 : 0

  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "capturelake"
  node_role_arn   = aws_iam_role.nodes.arn
  subnet_ids      = var.subnet_ids
  instance_types  = var.lake_node_instance_types
  capacity_type   = "ON_DEMAND"

  dynamic "launch_template" {
    for_each = var.enable_node_launch_template ? [1] : []
    content {
      id      = aws_launch_template.node[0].id
      version = aws_launch_template.node[0].latest_version
    }
  }

  scaling_config {
    min_size     = var.lake_node_min_size
    desired_size = var.lake_node_desired_size
    max_size     = var.lake_node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    workload = "capturelake"
  }

  taint {
    key    = "workload"
    value  = "capturelake"
    effect = "NO_SCHEDULE"
  }

  tags = merge(var.tags, {
    Name = "${local.cluster_name}-capturelake"
  })

  depends_on = [aws_iam_role_policy_attachment.nodes]
}

resource "aws_eks_addon" "this" {
  for_each = toset([
    "vpc-cni",
    "coredns",
    "kube-proxy",
  ])

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.value
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # IP-efficient warm pool so the stack fits a /24 VPC. By default the CNI keeps
  # a whole spare ENI warm (~10-15 IPs held per node even near-idle), which
  # exhausts a /26 per-AZ subnet fast. Keep the default reserve small; environments
  # with enough subnet capacity can raise it to cover bursts and IP cooldown.
  # MINIMUM_IP_TARGET keeps a floor for the first pods on a fresh node.
  #
  # ADDITIONAL_ENI_TAGS propagates the env tags onto the secondary ENIs the CNI
  # creates for pods at runtime via the node role (Terraform's default_tags
  # can't reach them), satisfying tag-enforcement SCPs that gate
  # ec2:CreateNetworkInterface.
  configuration_values = each.value == "vpc-cni" ? jsonencode(merge(
    {
      env = {
        WARM_IP_TARGET      = tostring(var.vpc_cni_warm_ip_target)
        MINIMUM_IP_TARGET   = "8"
        ADDITIONAL_ENI_TAGS = jsonencode(var.tags)
      }
    },
    var.enable_network_policy ? { enableNetworkPolicy = "true" } : {},
  )) : null

  tags = var.tags

  depends_on = [
    aws_eks_node_group.general,
    aws_eks_node_group.gpu,
    aws_eks_node_group.lake,
  ]
}

data "tls_certificate" "cluster" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.cluster.certificates[0].sha1_fingerprint]

  tags = var.tags
}
