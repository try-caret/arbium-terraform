variable "project_id" {
  description = "GCP project ID for the customer Arbium foundation."
  type        = string
}

variable "region" {
  description = "GCP region. Subnets and Cloud NAT live here."
  type        = string
  default     = "us-east1"
}

variable "name_prefix" {
  description = "External resource name prefix. Use arbium for customer-facing GCP/Kubernetes resources."
  type        = string
  default     = "arbium"
}

variable "environment" {
  description = "Environment name, e.g. dev, staging, prod."
  type        = string
  default     = "prod"
}

variable "labels" {
  description = "Additional labels applied to supported resources."
  type        = map(string)
  default     = {}
}

# -----------------------------------------------------------------------------
# Network
# -----------------------------------------------------------------------------

variable "subnet_cidr" {
  description = "Primary CIDR for the GKE node subnet."
  type        = string
  default     = "10.81.0.0/20"
}

variable "pods_cidr" {
  description = "Secondary range CIDR for GKE pods. Plan generously; not addressable outside the cluster."
  type        = string
  default     = "10.84.0.0/14"
}

variable "services_cidr" {
  description = "Secondary range CIDR for GKE services. /20 supports up to 4k services."
  type        = string
  default     = "10.82.0.0/20"
}

variable "psa_cidr" {
  description = "Private Service Access allocation CIDR for Cloud SQL/AlloyDB. /20 fits VPC peering minimums."
  type        = string
  default     = "10.83.0.0/20"
}

variable "enable_cloud_nat" {
  description = "Create Cloud NAT for controlled outbound egress from private nodes."
  type        = bool
  default     = true
}

variable "master_authorized_networks" {
  description = "CIDRs allowed to reach the GKE public API endpoint. Tighten in production."
  type = list(object({
    cidr         = string
    display_name = string
  }))
  default = [{
    cidr         = "0.0.0.0/0"
    display_name = "all"
  }]
}

# -----------------------------------------------------------------------------
# GKE
# -----------------------------------------------------------------------------

variable "cluster_release_channel" {
  description = "GKE release channel. REGULAR is the customer default; RAPID for early features; STABLE for slowest."
  type        = string
  default     = "REGULAR"
}

variable "cluster_endpoint_public_access" {
  description = "Whether the GKE API server has a public endpoint (restricted via master_authorized_networks)."
  type        = bool
  default     = true
}

variable "cluster_endpoint_private_access" {
  description = "Whether the GKE control plane has a private endpoint reachable from inside the VPC."
  type        = bool
  default     = true
}

variable "general_node_machine_type" {
  description = "Machine type for the general node pool."
  type        = string
  default     = "e2-standard-2"
}

variable "general_node_min_size" {
  description = "Minimum general node count per zone."
  type        = number
  default     = 1
}

variable "general_node_max_size" {
  description = "Maximum general node count per zone."
  type        = number
  default     = 3
}

variable "general_node_disk_size_gb" {
  description = "Boot disk size in GB for general nodes."
  type        = number
  default     = 50
}

variable "gpu_node_enabled" {
  description = "Create the embedder GPU node pool. Disable for environments without GPU quota."
  type        = bool
  default     = true
}

variable "gpu_node_machine_type" {
  description = "Machine type for the embedder GPU node pool. g2-standard-4 ships an L4."
  type        = string
  default     = "g2-standard-4"
}

variable "gpu_node_accelerator_type" {
  description = "GPU accelerator type."
  type        = string
  default     = "nvidia-l4"
}

variable "gpu_node_accelerator_count" {
  description = "GPUs per node."
  type        = number
  default     = 1
}

variable "gpu_node_min_size" {
  description = "Minimum GPU node count per zone."
  type        = number
  default     = 0
}

variable "gpu_node_max_size" {
  description = "Maximum GPU node count per zone."
  type        = number
  default     = 1
}

variable "gpu_node_disk_size_gb" {
  description = "Boot disk size in GB for GPU nodes."
  type        = number
  default     = 100
}

# -----------------------------------------------------------------------------
# Cloud SQL
# -----------------------------------------------------------------------------

variable "database_name" {
  description = "Initial ChainDB database name."
  type        = string
  default     = "chaindb"
}

variable "cloudsql_database_version" {
  description = "Cloud SQL Postgres version."
  type        = string
  default     = "POSTGRES_16"
}

variable "cloudsql_tier" {
  description = "Cloud SQL machine tier. db-custom-N-MMMM for ENTERPRISE; db-perf-optimized-N-MMMM for ENTERPRISE_PLUS."
  type        = string
  default     = "db-custom-2-7680"
}

variable "cloudsql_edition" {
  description = "Cloud SQL edition. ENTERPRISE supports custom tiers and is the default for cost. ENTERPRISE_PLUS unlocks higher availability and only accepts db-perf-optimized-* tiers."
  type        = string
  default     = "ENTERPRISE"
}

variable "cloudsql_disk_size_gb" {
  description = "Initial disk size for Cloud SQL. Autoresize is enabled."
  type        = number
  default     = 20
}

variable "cloudsql_disk_autoresize_limit_gb" {
  description = "Upper bound for disk autoresize. 0 = no upper bound."
  type        = number
  default     = 200
}

variable "cloudsql_availability_type" {
  description = "ZONAL for cheaper single-zone, REGIONAL for HA writer with sync standby."
  type        = string
  default     = "ZONAL"
}

variable "cloudsql_backup_retention_days" {
  description = "Number of automated backups to retain."
  type        = number
  default     = 7
}

variable "cloudsql_deletion_protection" {
  description = "Block accidental deletion of the Cloud SQL instance. Disable only for disposable environments."
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# Secret Manager
# -----------------------------------------------------------------------------

variable "secret_names" {
  description = "Secret Manager secret containers to create. Values are intentionally not managed by Terraform."
  type        = set(string)
  default = [
    "db",
    "scheduler",
    "scim",
    "sentry",
    "registry",
    "gemini",
    "enrollment",
    "jwt",
  ]
}

# -----------------------------------------------------------------------------
# Ingress
# -----------------------------------------------------------------------------

variable "ingress_static_ip_enabled" {
  description = "Reserve a global static external IP for the GCE Ingress. Recommended for production so DNS doesn't churn on chart re-install."
  type        = bool
  default     = true
}

variable "ingress_cloud_armor_enabled" {
  description = "Create a Cloud Armor security policy with rate limiting + OWASP preconfigured rules. Customer attaches via a BackendConfig CRD pointing at the policy name. Recommended for production."
  type        = bool
  default     = false
}

variable "cloud_armor_rate_limit_rpm" {
  description = "Cloud Armor per-IP request limit per minute. Requests above this return 429."
  type        = number
  default     = 600
}
