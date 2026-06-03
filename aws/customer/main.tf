data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = length(var.availability_zones) > 0 ? var.availability_zones : slice(data.aws_availability_zones.available.names, 0, 3)

  # The module deliberately does NOT emit an `environment` tag. It emits
  # `deployment` (the cluster name) as its per-stack identifier instead, so the
  # module's keys never overlap with caller-supplied keys like `environment`,
  # `team`, or `application`. This avoids IAM's case-insensitive duplicate-key
  # rejection (e.g. `Environment`+`environment`) entirely: every key below is
  # distinct from var.tags, so merge() only ever adds — it never overwrites.
  tags = merge(
    {
      Project    = "Arbium"
      Component  = "ChainDB"
      deployment = "${var.name_prefix}-${var.environment}"
      ManagedBy  = "Terraform"
    },
    var.tags,
  )
}

module "network" {
  source = "./modules/network"

  name_prefix                 = var.name_prefix
  environment                 = var.environment
  vpc_cidr                    = var.vpc_cidr
  availability_zones          = local.azs
  private_subnet_cidrs        = var.private_subnet_cidrs
  public_subnet_cidrs         = var.public_subnet_cidrs
  create_public_subnets       = var.create_public_subnets
  enable_nat_gateway          = var.enable_nat_gateway
  single_nat_gateway          = var.single_nat_gateway
  enable_vpc_endpoints        = var.enable_vpc_endpoints
  interface_endpoint_services = var.interface_endpoint_services
  tags                        = local.tags
}

module "eks" {
  source = "./modules/eks"

  name_prefix                     = var.name_prefix
  environment                     = var.environment
  cluster_version                 = var.cluster_version
  vpc_id                          = module.network.vpc_id
  subnet_ids                      = module.network.private_subnet_ids
  cluster_endpoint_public_access  = var.cluster_endpoint_public_access
  cluster_endpoint_private_access = var.cluster_endpoint_private_access
  general_node_instance_types     = var.general_node_instance_types
  general_node_min_size           = var.general_node_min_size
  general_node_desired_size       = var.general_node_desired_size
  general_node_max_size           = var.general_node_max_size
  gpu_node_instance_types         = var.gpu_node_instance_types
  gpu_node_ami_type               = var.gpu_node_ami_type
  gpu_node_min_size               = var.gpu_node_min_size
  gpu_node_desired_size           = var.gpu_node_desired_size
  gpu_node_max_size               = var.gpu_node_max_size
  enable_node_launch_template     = var.enable_node_launch_template
  tags                            = local.tags
}

# AWS Secrets Manager has a 7-30 day deletion window. If terraform destroyed
# this env recently and you're re-applying, secrets with the same names are
# still scheduled-for-deletion and CreateSecret returns InvalidRequestException.
# Auto-recover by force-deleting any pending secrets that match this env's
# name pattern before the secrets module tries to create them.
resource "null_resource" "purge_pending_secrets" {
  triggers = {
    # Re-run on env change. Doesn't run if env hasn't changed AND state
    # already contains a prior successful purge.
    env = "${var.name_prefix}/${var.environment}"
  }

  provisioner "local-exec" {
    command = <<-EOT
      for name in ${join(" ", var.secret_names)}; do
        aws secretsmanager describe-secret \
          --secret-id "${var.name_prefix}/${var.environment}/$name" \
          --region "${var.aws_region}" >/dev/null 2>&1 || continue
        if aws secretsmanager describe-secret \
            --secret-id "${var.name_prefix}/${var.environment}/$name" \
            --region "${var.aws_region}" \
            --query 'DeletedDate' --output text 2>/dev/null | grep -qv None; then
          echo "Force-deleting scheduled-for-deletion secret: $name"
          aws secretsmanager delete-secret \
            --secret-id "${var.name_prefix}/${var.environment}/$name" \
            --force-delete-without-recovery \
            --region "${var.aws_region}" >/dev/null 2>&1 || true
        fi
      done
    EOT
  }
}

module "secrets" {
  source = "./modules/secrets"

  name_prefix  = var.name_prefix
  environment  = var.environment
  secret_names = var.secret_names
  kms_key_id   = var.secrets_kms_key_id
  tags         = local.tags

  depends_on = [null_resource.purge_pending_secrets]
}

module "aurora" {
  source = "./modules/aurora"

  name_prefix                = var.name_prefix
  environment                = var.environment
  vpc_id                     = module.network.vpc_id
  subnet_ids                 = module.network.private_subnet_ids
  eks_node_security_group_id = module.eks.node_security_group_id
  database_name              = var.database_name
  engine_version             = var.aurora_engine_version
  serverless_min_acu         = var.aurora_serverless_min_acu
  serverless_max_acu         = var.aurora_serverless_max_acu
  instance_count             = var.aurora_instance_count
  backup_retention_days      = var.aurora_backup_retention_days
  deletion_protection        = var.aurora_deletion_protection
  skip_final_snapshot        = var.aurora_skip_final_snapshot
  enable_http_endpoint       = var.aurora_enable_http_endpoint
  tags                       = local.tags
}
