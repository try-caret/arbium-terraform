locals {
  name = "${var.name_prefix}-${var.environment}"
}

# Random instance suffix — Cloud SQL retains instance names for 7 days after delete, so
# repeated apply/destroy cycles need a fresh suffix to avoid name collisions.
resource "random_id" "instance_suffix" {
  byte_length = 2
}

resource "google_sql_database_instance" "this" {
  project          = var.project_id
  name             = "${local.name}-pg-${random_id.instance_suffix.hex}"
  region           = var.region
  database_version = var.database_version

  deletion_protection = var.deletion_protection

  settings {
    # ENTERPRISE supports db-custom-* and shared tiers. ENTERPRISE_PLUS is the new default
    # for newly-created instances and only accepts db-perf-optimized-* tiers, which are
    # roughly 2-4x more expensive. Override via var.cloudsql_edition for HA features.
    edition               = var.edition
    tier                  = var.tier
    availability_type     = var.availability_type
    disk_size             = var.disk_size_gb
    disk_type             = "PD_SSD"
    disk_autoresize       = true
    disk_autoresize_limit = var.disk_autoresize_limit_gb

    user_labels = var.labels

    ip_configuration {
      ipv4_enabled                                  = false
      private_network                               = var.network_id
      enable_private_path_for_google_cloud_services = true
    }

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      backup_retention_settings {
        retained_backups = var.backup_retention_days
      }
      # PITR transaction log retention. Cloud SQL requires this to be <= backup_retention_days.
      transaction_log_retention_days = var.backup_retention_days
      start_time                     = "07:00"
    }

    maintenance_window {
      day          = 7 # Sunday
      hour         = 8
      update_track = "stable"
    }

    insights_config {
      query_insights_enabled  = true
      record_application_tags = false
      record_client_address   = false
    }

    # pgvector on Cloud SQL Postgres 15+ is available without a database flag.
    # Run `CREATE EXTENSION vector;` against the target database via the migration runner.
  }

  lifecycle {
    ignore_changes = [
      settings[0].disk_size, # autoresize will mutate this
    ]
  }
}

resource "google_sql_database" "chaindb" {
  project  = var.project_id
  name     = var.database_name
  instance = google_sql_database_instance.this.name
}

resource "random_password" "admin" {
  count = var.create_admin_user ? 1 : 0

  length           = 32
  special          = true
  override_special = "!@#%^&*()-_=+[]{}<>?"
}

resource "google_sql_user" "admin" {
  count = var.create_admin_user ? 1 : 0

  project  = var.project_id
  name     = "chaindb_admin"
  instance = google_sql_database_instance.this.name
  password = random_password.admin[0].result
}

# Mirror RDS's master-user-secret pattern by storing the generated admin password in
# Secret Manager. Operators rotate by overwriting this secret. Hosted cloud disables
# this path so Terraform never stores DB credentials in state.
resource "google_secret_manager_secret" "admin_password" {
  count = var.create_admin_user ? 1 : 0

  project   = var.project_id
  secret_id = "${local.name}-cloudsql-admin"

  labels = var.labels

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "admin_password" {
  count = var.create_admin_user ? 1 : 0

  secret      = google_secret_manager_secret.admin_password[0].id
  secret_data = random_password.admin[0].result
}

# Dedicated GSA for the Cloud SQL Auth Proxy running in-cluster. The proxy
# Pod uses Workload Identity to impersonate this GSA; the GSA holds
# roles/cloudsql.client which is all the proxy needs.
resource "google_service_account" "cloudsql_proxy" {
  count = var.create_proxy_sa ? 1 : 0

  project      = var.project_id
  account_id   = "${local.name}-csqlproxy"
  display_name = "Cloud SQL Auth Proxy for ${local.name}"
}

resource "google_project_iam_member" "cloudsql_proxy_client" {
  count = var.create_proxy_sa ? 1 : 0

  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.cloudsql_proxy[0].email}"
}

# Bind the Helm chart's KSA (arbium/cloud-sql-proxy by default) to
# impersonate the proxy GSA via Workload Identity.
resource "google_service_account_iam_member" "cloudsql_proxy_wi" {
  count = var.create_proxy_sa ? 1 : 0

  service_account_id = google_service_account.cloudsql_proxy[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.proxy_workload_identity_namespace}/${var.proxy_workload_identity_ksa_name}]"
}
