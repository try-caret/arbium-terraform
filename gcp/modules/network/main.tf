locals {
  name = "${var.name_prefix}-${var.environment}"
}

resource "google_compute_network" "this" {
  project                 = var.project_id
  name                    = local.name
  description             = "Dedicated VPC for Arbium ${var.environment}"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "nodes" {
  project = var.project_id
  name    = "${local.name}-nodes"
  region  = var.region
  network = google_compute_network.this.id

  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "${local.name}-pods"
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = "${local.name}-services"
    ip_cidr_range = var.services_cidr
  }

  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.1
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# Cloud NAT for controlled egress from private GKE nodes.
resource "google_compute_router" "nat" {
  count = var.enable_cloud_nat ? 1 : 0

  project = var.project_id
  name    = "${local.name}-nat"
  region  = var.region
  network = google_compute_network.this.id
}

resource "google_compute_router_nat" "this" {
  count = var.enable_cloud_nat ? 1 : 0

  project                            = var.project_id
  name                               = "${local.name}-nat"
  router                             = google_compute_router.nat[0].name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# Private Service Access — gives Cloud SQL/AlloyDB a peered private range.
resource "google_compute_global_address" "psa" {
  project       = var.project_id
  name          = "${local.name}-psa"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = tonumber(split("/", var.psa_cidr)[1])
  address       = split("/", var.psa_cidr)[0]
  network       = google_compute_network.this.id
}

resource "google_service_networking_connection" "psa" {
  network                 = google_compute_network.this.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psa.name]

  deletion_policy = "ABANDON"
}

# Firewall: allow internal VPC traffic (pods + nodes).
resource "google_compute_firewall" "internal" {
  project = var.project_id
  name    = "${local.name}-allow-internal"
  network = google_compute_network.this.name

  direction = "INGRESS"
  priority  = 1000

  source_ranges = [
    var.subnet_cidr,
    var.pods_cidr,
    var.services_cidr,
  ]

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }
}

# Firewall: allow Google health checkers to reach LB-backed services.
resource "google_compute_firewall" "lb_health_checks" {
  project = var.project_id
  name    = "${local.name}-allow-lb-health"
  network = google_compute_network.this.name

  direction = "INGRESS"
  priority  = 1000

  # Standard Google LB / health check ranges.
  source_ranges = [
    "35.191.0.0/16",
    "130.211.0.0/22",
  ]

  allow {
    protocol = "tcp"
  }
}
