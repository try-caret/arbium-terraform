locals {
  name = "${var.name_prefix}-${var.environment}"
}

# Dedicated service account for GKE nodes — least-privilege, principle of separate identity per workload.
resource "google_service_account" "nodes" {
  project      = var.project_id
  account_id   = "${local.name}-gke-nodes"
  display_name = "GKE nodes for ${local.name}"
}

# Roles required for nodes to function (logging, monitoring, container registry pulls).
resource "google_project_iam_member" "nodes_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

resource "google_project_iam_member" "nodes_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

resource "google_project_iam_member" "nodes_monitoring_viewer" {
  project = var.project_id
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

resource "google_project_iam_member" "nodes_artifact_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

# Regional GKE Standard cluster with Workload Identity.
resource "google_container_cluster" "this" {
  provider = google-beta

  project  = var.project_id
  name     = local.name
  location = var.region

  # Remove the default node pool — we create our own with finer control.
  remove_default_node_pool = true
  initial_node_count       = 1
  deletion_protection      = false

  network    = var.network_id
  subnetwork = var.subnet_id

  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_secondary_range_name
    services_secondary_range_name = var.services_secondary_range_name
  }

  release_channel {
    channel = var.cluster_release_channel
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = !var.cluster_endpoint_public_access
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.master_authorized_networks
      content {
        cidr_block   = cidr_blocks.value.cidr
        display_name = cidr_blocks.value.display_name
      }
    }
  }

  addons_config {
    horizontal_pod_autoscaling {
      disabled = false
    }
    http_load_balancing {
      disabled = false
    }
    gcp_filestore_csi_driver_config {
      enabled = false
    }
    gce_persistent_disk_csi_driver_config {
      enabled = true
    }
  }

  resource_labels = var.labels

  lifecycle {
    ignore_changes = [initial_node_count]
  }
}

resource "google_container_node_pool" "general" {
  provider = google-beta

  project  = var.project_id
  name     = "general"
  cluster  = google_container_cluster.this.name
  location = var.region

  autoscaling {
    min_node_count = var.general_node_min_size
    max_node_count = var.general_node_max_size
  }

  initial_node_count = var.general_node_min_size

  node_config {
    machine_type = var.general_node_machine_type
    disk_size_gb = var.general_node_disk_size_gb
    disk_type    = "pd-balanced"
    image_type   = "COS_CONTAINERD"

    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    labels = merge(var.labels, {
      pool = "general"
    })
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  lifecycle {
    ignore_changes = [initial_node_count, node_config[0].labels]
  }
}

resource "google_container_node_pool" "embedder_gpu" {
  provider = google-beta
  count    = var.gpu_node_enabled ? 1 : 0

  project  = var.project_id
  name     = "embedder-gpu"
  cluster  = google_container_cluster.this.name
  location = var.region

  autoscaling {
    min_node_count = var.gpu_node_min_size
    max_node_count = var.gpu_node_max_size
  }

  initial_node_count = var.gpu_node_min_size

  node_config {
    machine_type = var.gpu_node_machine_type
    disk_size_gb = var.gpu_node_disk_size_gb
    disk_type    = "pd-balanced"
    image_type   = "COS_CONTAINERD"

    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    guest_accelerator {
      type  = var.gpu_node_accelerator_type
      count = var.gpu_node_accelerator_count

      gpu_driver_installation_config {
        gpu_driver_version = "LATEST"
      }
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    taint {
      key    = "workload"
      value  = "embedder"
      effect = "NO_SCHEDULE"
    }

    taint {
      key    = "nvidia.com/gpu"
      value  = "present"
      effect = "NO_SCHEDULE"
    }

    labels = merge(var.labels, {
      pool     = "embedder-gpu"
      workload = "embedder"
    })
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  lifecycle {
    ignore_changes = [initial_node_count, node_config[0].labels]
  }
}
