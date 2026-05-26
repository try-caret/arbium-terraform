# Arbium customer GCP foundation example values.
# Copy this file to an environment-specific tfvars file and adjust values.
# Do not put secret values in tfvars.

project_id  = "<gcp-project-id>"
region      = "us-east1"
environment = "example"
name_prefix = "arbium"

# Network
subnet_cidr   = "10.81.0.0/20"
pods_cidr     = "10.84.0.0/14"
services_cidr = "10.82.0.0/20"
psa_cidr      = "10.83.0.0/20"

enable_cloud_nat = true

# Tighten in production. The wide-open default is for testing only.
master_authorized_networks = [
  {
    cidr         = "0.0.0.0/0"
    display_name = "all"
  },
]

# GKE
cluster_release_channel         = "REGULAR"
cluster_endpoint_public_access  = true
cluster_endpoint_private_access = true

general_node_machine_type = "e2-standard-2"
general_node_min_size     = 1
general_node_max_size     = 3
general_node_disk_size_gb = 50

# GPU embedder pool. Keep enabled=false unless the account has GPU quota.
gpu_node_enabled           = true
gpu_node_machine_type      = "g2-standard-4"
gpu_node_accelerator_type  = "nvidia-l4"
gpu_node_accelerator_count = 1
gpu_node_min_size          = 0
gpu_node_max_size          = 1
gpu_node_disk_size_gb      = 100

# Cloud SQL
database_name                     = "chaindb"
cloudsql_database_version         = "POSTGRES_16"
cloudsql_tier                     = "db-custom-2-7680"
cloudsql_disk_size_gb             = 20
cloudsql_disk_autoresize_limit_gb = 200
cloudsql_availability_type        = "ZONAL"
cloudsql_backup_retention_days    = 7
cloudsql_deletion_protection      = true

# Secret containers only. Populate values out-of-band in Secret Manager.
secret_names = ["db", "scheduler", "scim", "sentry", "registry", "gemini", "enrollment", "jwt"]

labels = {
  owner = "platform"
  env   = "example"
}
