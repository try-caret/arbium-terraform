locals {
  labels = merge(
    {
      project     = "arbium"
      component   = "chaindb"
      environment = var.environment
      managed-by  = "terraform"
    },
    var.labels,
  )
}

module "network" {
  source = "../modules/network"

  project_id       = var.project_id
  region           = var.region
  name_prefix      = var.name_prefix
  environment      = var.environment
  subnet_cidr      = var.subnet_cidr
  pods_cidr        = var.pods_cidr
  services_cidr    = var.services_cidr
  psa_cidr         = var.psa_cidr
  enable_cloud_nat = var.enable_cloud_nat
  labels           = local.labels
}

module "gke" {
  source = "../modules/gke"

  project_id                      = var.project_id
  region                          = var.region
  name_prefix                     = var.name_prefix
  environment                     = var.environment
  network_id                      = module.network.network_id
  subnet_id                       = module.network.subnet_id
  pods_secondary_range_name       = module.network.pods_secondary_range_name
  services_secondary_range_name   = module.network.services_secondary_range_name
  cluster_release_channel         = var.cluster_release_channel
  cluster_endpoint_public_access  = var.cluster_endpoint_public_access
  cluster_endpoint_private_access = var.cluster_endpoint_private_access
  master_authorized_networks      = var.master_authorized_networks
  general_node_machine_type       = var.general_node_machine_type
  general_node_min_size           = var.general_node_min_size
  general_node_max_size           = var.general_node_max_size
  general_node_disk_size_gb       = var.general_node_disk_size_gb
  gpu_node_enabled                = var.gpu_node_enabled
  gpu_node_machine_type           = var.gpu_node_machine_type
  gpu_node_accelerator_type       = var.gpu_node_accelerator_type
  gpu_node_accelerator_count      = var.gpu_node_accelerator_count
  gpu_node_min_size               = var.gpu_node_min_size
  gpu_node_max_size               = var.gpu_node_max_size
  gpu_node_disk_size_gb           = var.gpu_node_disk_size_gb
  labels                          = local.labels
}

module "cloudsql" {
  source = "../modules/cloudsql"

  project_id               = var.project_id
  region                   = var.region
  name_prefix              = var.name_prefix
  environment              = var.environment
  network_id               = module.network.network_id
  database_name            = var.database_name
  database_version         = var.cloudsql_database_version
  tier                     = var.cloudsql_tier
  edition                  = var.cloudsql_edition
  disk_size_gb             = var.cloudsql_disk_size_gb
  disk_autoresize_limit_gb = var.cloudsql_disk_autoresize_limit_gb
  availability_type        = var.cloudsql_availability_type
  backup_retention_days    = var.cloudsql_backup_retention_days
  deletion_protection      = var.cloudsql_deletion_protection
  create_admin_user        = var.cloudsql_create_admin_user
  labels                   = local.labels

  depends_on = [module.network]
}

module "secrets" {
  source = "../modules/secrets"

  project_id   = var.project_id
  name_prefix  = var.name_prefix
  environment  = var.environment
  secret_names = var.secret_names
  labels       = local.labels
}

# Reserved global external IP for the GCE Ingress. The LB IP survives chart
# re-installs as long as this resource exists. Customer points DNS at this IP
# and the chart references the name via
# kubernetes.io/ingress.global-static-ip-name.
resource "google_compute_global_address" "ingress" {
  count = var.ingress_static_ip_enabled ? 1 : 0

  project    = var.project_id
  name       = "${var.name_prefix}-${var.environment}-ingress"
  ip_version = "IPV4"
}

# Cloud Armor security policy for the public ingress. Attach to the GKE
# Ingress via a BackendConfig CRD that references this policy by name:
#
#   apiVersion: cloud.google.com/v1
#   kind: BackendConfig
#   metadata: { name: chaindb-edge-fns, namespace: arbium }
#   spec:
#     securityPolicy:
#       name: arbium-<env>-armor
#
# Then annotate the edge-fns Service with cloud.google.com/backend-config.
resource "google_compute_security_policy" "ingress" {
  count = var.ingress_cloud_armor_enabled ? 1 : 0

  project     = var.project_id
  name        = "${var.name_prefix}-${var.environment}-armor"
  description = "Cloud Armor policy for the Arbium ingress"

  # Default rule: allow. Lower-priority numbered rules below add restrictions.
  rule {
    action   = "allow"
    priority = "2147483647"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    description = "default allow"
  }

  # Rate limit per source IP. Throttles brute-force / abuse without blocking
  # legitimate clients.
  rule {
    action   = "throttle"
    priority = "1000"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      rate_limit_threshold {
        count        = var.cloud_armor_rate_limit_rpm
        interval_sec = 60
      }
      enforce_on_key = "IP"
    }
    description = "per-IP rate limit"
  }

  # OWASP top 10 — SQLi.
  rule {
    action   = "deny(403)"
    priority = "2000"
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('sqli-v33-stable')"
      }
    }
    description = "block SQL injection signatures"
  }

  # OWASP top 10 — XSS.
  rule {
    action   = "deny(403)"
    priority = "2001"
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('xss-v33-stable')"
      }
    }
    description = "block cross-site scripting signatures"
  }

  # OWASP top 10 — Remote Code Execution.
  rule {
    action   = "deny(403)"
    priority = "2002"
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('rce-v33-stable')"
      }
    }
    description = "block remote code execution signatures"
  }

  adaptive_protection_config {
    layer_7_ddos_defense_config {
      enable = true
    }
  }
}
