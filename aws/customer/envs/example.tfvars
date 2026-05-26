# Arbium customer AWS foundation example values.
# Copy this file to an environment-specific tfvars file and adjust values.
# Do not put secret values in tfvars.

aws_region  = "us-east-1"
environment = "example"
name_prefix = "arbium"

vpc_cidr = "10.81.0.0/16"

# Leave empty to use the first three AZs in aws_region.
private_subnet_cidrs = ["10.81.0.0/20", "10.81.16.0/20", "10.81.32.0/20"]
public_subnet_cidrs  = ["10.81.240.0/24", "10.81.241.0/24", "10.81.242.0/24"]

create_public_subnets = true
enable_nat_gateway    = true
single_nat_gateway    = true

enable_vpc_endpoints = true
interface_endpoint_services = [
  "sts",
  "secretsmanager",
  "logs",
  "ecr.api",
  "ecr.dkr",
  "bedrock-runtime",
  "bedrock",
]

cluster_version                 = "1.31"
cluster_endpoint_public_access  = true
cluster_endpoint_private_access = true

general_node_instance_types = ["m6i.large"]
general_node_min_size       = 1
general_node_desired_size   = 1
general_node_max_size       = 3

# GPU embedder node group. Keep desired at 0 unless the account has GPU vCPU quota.
# Set desired/max to 1+ to enable the GPU embedder path.
gpu_node_instance_types = ["g4dn.xlarge"]
gpu_node_ami_type       = "AL2_x86_64_GPU"
gpu_node_min_size       = 0
gpu_node_desired_size   = 0
gpu_node_max_size       = 1

# Installs NVIDIA's Kubernetes device plugin on GPU nodes so pods can request nvidia.com/gpu.
enable_nvidia_device_plugin = true

# Secret containers only. Populate values out-of-band in AWS Secrets Manager.
secret_names = ["db", "scheduler", "scim", "sentry", "registry", "gemini"]

# Aurora sizing. App traffic uses the Aurora writer endpoint.
database_name                = "chaindb"
aurora_engine_version        = "16.13"
aurora_serverless_min_acu    = 0.5
aurora_serverless_max_acu    = 4
aurora_instance_count        = 1
aurora_backup_retention_days = 7
aurora_deletion_protection   = true
aurora_skip_final_snapshot   = false

# RDS Data API (HTTPS+SigV4 query endpoint). Lets the AWS Console Query
# Editor + rds-data SDK callers query the cluster without VPC connectivity.
# All traffic stays TLS despite the AWS-named "http" parameter.
aurora_enable_http_endpoint = false

tags = {
  Owner = "platform"
  Env   = "example"
}
