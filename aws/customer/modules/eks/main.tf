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
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  for_each = toset([
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy",
  ])

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
  # exhausts a /26 per-AZ subnet fast. WARM_IP_TARGET holds only (running pods
  # + 2) IPs; MINIMUM_IP_TARGET keeps a small floor so fresh nodes schedule
  # their first pods without an extra EC2 AllocateIPs round-trip. Trade-off:
  # slightly more EC2 API calls under burst scheduling — negligible here.
  #
  # ADDITIONAL_ENI_TAGS propagates the env tags onto the secondary ENIs the CNI
  # creates for pods at runtime via the node role (Terraform's default_tags
  # can't reach them), satisfying tag-enforcement SCPs that gate
  # ec2:CreateNetworkInterface.
  configuration_values = each.value == "vpc-cni" ? jsonencode({
    env = {
      WARM_IP_TARGET      = "2"
      MINIMUM_IP_TARGET   = "8"
      ADDITIONAL_ENI_TAGS = jsonencode(var.tags)
    }
  }) : null

  tags = var.tags

  depends_on = [
    aws_eks_node_group.general,
    aws_eks_node_group.gpu,
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
