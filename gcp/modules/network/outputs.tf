output "network_id" {
  value = google_compute_network.this.id
}

output "network_name" {
  value = google_compute_network.this.name
}

output "network_self_link" {
  value = google_compute_network.this.self_link
}

output "subnet_id" {
  value = google_compute_subnetwork.nodes.id
}

output "subnet_name" {
  value = google_compute_subnetwork.nodes.name
}

output "subnet_self_link" {
  value = google_compute_subnetwork.nodes.self_link
}

output "pods_secondary_range_name" {
  value = google_compute_subnetwork.nodes.secondary_ip_range[0].range_name
}

output "services_secondary_range_name" {
  value = google_compute_subnetwork.nodes.secondary_ip_range[1].range_name
}

output "psa_connection_id" {
  value = google_service_networking_connection.psa.id
}
