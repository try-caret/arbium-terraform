locals {
  name = "${var.name_prefix}-${var.environment}"
}

resource "google_secret_manager_secret" "this" {
  for_each = var.secret_names

  project   = var.project_id
  secret_id = "${local.name}-${each.value}"

  labels = var.labels

  replication {
    auto {}
  }
}

# Dedicated GSA for External Secrets Operator running in-cluster. The ESO
# ClusterSecretStore uses Workload Identity to impersonate this GSA when
# pulling values from Secret Manager. Holds only secretAccessor.
resource "google_service_account" "eso" {
  count = var.create_eso_sa ? 1 : 0

  project      = var.project_id
  account_id   = "${local.name}-eso"
  display_name = "External Secrets Operator for ${local.name}"
}

resource "google_project_iam_member" "eso_secret_accessor" {
  count = var.create_eso_sa ? 1 : 0

  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.eso[0].email}"
}

resource "google_service_account_iam_member" "eso_wi" {
  count = var.create_eso_sa ? 1 : 0

  service_account_id = google_service_account.eso[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.eso_workload_identity_namespace}/${var.eso_workload_identity_ksa_name}]"
}
