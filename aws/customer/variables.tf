variable "aws_region" {
  description = "AWS region to deploy the customer Arbium foundation into."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "External resource name prefix. Use arbium for customer-facing AWS/Kubernetes resources."
  type        = string
  default     = "arbium"
}

variable "environment" {
  description = "Environment name, e.g. dev, staging, prod."
  type        = string
  default     = "prod"
}

variable "tags" {
  description = "Additional tags applied to all supported resources."
  type        = map(string)
  default     = {}
}

variable "create_ingress_certificate" {
  description = "Request an ACM certificate for the Arbium HTTPS ingress. Terraform outputs DNS validation records for the customer's DNS provider."
  type        = bool
  default     = false
}

variable "ingress_domain_name" {
  description = "Full customer-owned DNS name for the Arbium HTTPS endpoint, e.g. chaindb.customer.example. Required when create_ingress_certificate is true."
  type        = string
  default     = ""

  validation {
    condition = trimspace(var.ingress_domain_name) == "" || (
      can(regex("^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$", trimspace(var.ingress_domain_name))) &&
      !can(regex("\\.$", trimspace(var.ingress_domain_name)))
    )
    error_message = "ingress_domain_name must be a full DNS name such as chaindb.customer.example, without a trailing dot."
  }
}


variable "vpc_cidr" {
  description = "CIDR block for the dedicated Arbium VPC. Default is a /24 — a single ChainDB customer cluster fits comfortably in 256 IPs given the WARM_IP_TARGET CNI tuning (see modules/eks). Widen to /22+ only for heavy autoscale or multi-cluster."
  type        = string
  default     = "10.80.0.0/24"
}

variable "availability_zones" {
  description = "Availability zones to use. Leave empty to use the first three available AZs in aws_region."
  type        = list(string)
  default     = []
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDRs, one per selected AZ. Default carves three /26s (59 usable each) out of the /24 vpc_cidr — holds nodes, pods (warm-pool-tuned CNI), VPC endpoints, and Aurora."
  type        = list(string)
  default     = ["10.80.0.0/26", "10.80.0.64/26", "10.80.0.128/26"]
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDRs, one per selected AZ. Required when create_public_subnets is true. Default carves three /28s (11 usable each) for the ALB + NAT — meets the ALB 8-free-IP minimum. Drop to 2 AZs (bigger subnets) if the internet-facing ALB needs more headroom."
  type        = list(string)
  default     = ["10.80.0.192/28", "10.80.0.208/28", "10.80.0.224/28"]
}

variable "create_public_subnets" {
  description = "Create public subnets for internet-facing ALB/NAT. Disable for fully private/customer-routed environments."
  type        = bool
  default     = true
}

variable "enable_nat_gateway" {
  description = "Create NAT gateways for controlled non-private-data egress such as image registry/Sentry."
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "Use one NAT gateway instead of one per AZ. Cheaper for pilots; less HA."
  type        = bool
  default     = true
}

variable "enable_vpc_endpoints" {
  description = "Create VPC endpoints for AWS services carrying private data where available."
  type        = bool
  default     = true
}

variable "interface_endpoint_services" {
  description = "Interface endpoint service short names. Service availability varies by region; remove unsupported names in tfvars."
  type        = set(string)
  default = [
    "sts",
    "secretsmanager",
    "logs",
    "ecr.api",
    "ecr.dkr",
    "bedrock-runtime",
    "bedrock"
  ]
}

variable "cluster_version" {
  description = "EKS Kubernetes version."
  type        = string
  default     = "1.31"
}

variable "cluster_endpoint_public_access" {
  description = "Whether the EKS API server has a public endpoint."
  type        = bool
  default     = true
}

variable "cluster_endpoint_private_access" {
  description = "Whether the EKS API server has a private VPC endpoint."
  type        = bool
  default     = true
}

variable "enable_node_launch_template" {
  description = "Attach a launch template to the managed node groups so the required tags propagate to EC2 instances, EBS volumes, and primary ENIs. Off by default; enabling replaces existing node groups. Set true for tag-enforced customer accounts."
  type        = bool
  default     = false
}

variable "general_node_instance_types" {
  description = "Instance types for the general managed node group."
  type        = list(string)
  default     = ["m7i.large", "m6i.large"]
}

variable "general_node_min_size" {
  type        = number
  description = "Minimum general node count."
  default     = 2
}

variable "general_node_desired_size" {
  type        = number
  description = "Desired general node count."
  default     = 2
}

variable "general_node_max_size" {
  type        = number
  description = "Maximum general node count."
  default     = 5
}

variable "gpu_node_instance_types" {
  description = "Instance types for the optional embedder GPU managed node group. g4dn.xlarge is the lower-cost default; use g5/g6 when throughput requires it."
  type        = list(string)
  default     = ["g4dn.xlarge"]
}

variable "gpu_node_ami_type" {
  description = "AMI type for the optional embedder GPU managed node group. Use an EKS accelerated AMI so NVIDIA drivers/runtime are present."
  type        = string
  default     = "AL2_x86_64_GPU"
}

variable "gpu_node_min_size" {
  type        = number
  description = "Minimum GPU node count. Use 0 for cost-minimal non-ingest environments."
  default     = 1
}

variable "gpu_node_desired_size" {
  type        = number
  description = "Desired GPU node count for the pilot."
  default     = 1
}

variable "gpu_node_max_size" {
  type        = number
  description = "Maximum GPU node count."
  default     = 2
}

variable "enable_nvidia_device_plugin" {
  type        = bool
  description = "Install the NVIDIA Kubernetes device plugin on GPU nodes so pods can request nvidia.com/gpu."
  default     = true
}

variable "nvidia_device_plugin_chart_version" {
  type        = string
  description = "NVIDIA k8s-device-plugin Helm chart version."
  default     = "0.17.1"
}

variable "secret_names" {
  description = "Secrets Manager secret containers to create. Values are intentionally not managed by Terraform."
  type        = set(string)
  default = [
    "db",
    "scheduler",
    "scim",
    "sentry",
    "registry",
    "gemini",
    "enrollment",
    "jwt"
  ]
}

variable "secrets_kms_key_id" {
  description = "Optional KMS key ID/ARN for Secrets Manager secret containers. Null uses AWS-managed key."
  type        = string
  default     = null
}

variable "database_name" {
  description = "Initial ChainDB database name."
  type        = string
  default     = "chaindb"
}

variable "aurora_engine_version" {
  description = "Aurora PostgreSQL engine version."
  type        = string
  default     = "16.13"
}

variable "aurora_serverless_min_acu" {
  description = "Aurora Serverless v2 minimum ACUs."
  type        = number
  default     = 0.5
}

variable "aurora_serverless_max_acu" {
  description = "Aurora Serverless v2 maximum ACUs."
  type        = number
  default     = 4
}

variable "aurora_instance_count" {
  description = "Number of Aurora db.serverless instances."
  type        = number
  default     = 1
}

variable "aurora_backup_retention_days" {
  description = "Aurora backup retention in days."
  type        = number
  default     = 7
}

variable "aurora_deletion_protection" {
  description = "Enable deletion protection for Aurora. Disable only for disposable QA environments."
  type        = bool
  default     = false
}

variable "aurora_skip_final_snapshot" {
  description = "Skip final snapshot on Aurora deletion. Use false for production."
  type        = bool
  default     = true
}

variable "aurora_enable_http_endpoint" {
  description = "Enable the Aurora RDS Data API (HTTPS+SigV4 query endpoint via the AWS Console Query Editor or rds-data: SDK). No VPC connectivity required for callers. Despite the parameter name, all traffic is HTTPS."
  type        = bool
  default     = false
}

# ─────────────────────────────────────────────────────────────────────────────
# Cluster addons (LBC + ESO) — see addons.tf
# ─────────────────────────────────────────────────────────────────────────────

variable "enable_lb_controller" {
  description = "Install AWS Load Balancer Controller. Required for the Arbium chart's Ingress to become a real ALB."
  type        = bool
  default     = true
}

variable "lb_controller_chart_version" {
  description = "Helm chart version for aws-load-balancer-controller. Track upstream eks-charts release notes before bumping."
  type        = string
  default     = "1.10.0"
}

variable "enable_eso" {
  description = "Install External Secrets Operator + IRSA role for the chart's `eso` KSA. Required if externalSecrets.enabled=true in the ChainDB chart values."
  type        = bool
  default     = true
}

variable "eso_chart_version" {
  description = "Helm chart version for external-secrets. 2.0+ serves the v1 API the ChainDB chart uses; older ESO only serves v1beta1."
  type        = string
  default     = "2.5.0"
}

variable "arbium_namespace" {
  description = "Kubernetes namespace the ChainDB chart installs into. Determines IRSA subject for the `eso` SA."
  type        = string
  default     = "arbium"
}

variable "enable_capturelake" {
  description = "Provision the CaptureLake S3 data bucket + IRSA role for the `chaindb-capturelake` KSA. Set when capturelake.enabled=true in the ChainDB chart values."
  type        = bool
  default     = false
}

variable "enable_reloader" {
  description = "Install Stakater Reloader (cluster-wide controller that rolls Deployments the ChainDB chart annotates when chaindb-runtime rotates). Required for secret-rotation self-heal; harmless no-op if no workload is annotated."
  type        = bool
  default     = true
}

variable "reloader_chart_version" {
  description = "Helm CHART version for stakater/reloader (note: chart 2.2.x packages app v1.4.x — do not confuse the two). Verify with `helm search repo stakater/reloader --versions` before bumping."
  type        = string
  default     = "2.2.12"
}
