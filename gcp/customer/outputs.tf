output "network_id" {
  description = "Self-link of the dedicated Arbium VPC."
  value       = module.network.network_id
}

output "network_name" {
  description = "Name of the dedicated Arbium VPC."
  value       = module.network.network_name
}

output "subnet_id" {
  description = "Self-link of the GKE subnet."
  value       = module.network.subnet_id
}

output "cluster_name" {
  description = "GKE cluster name."
  value       = module.gke.cluster_name
}

output "cluster_endpoint" {
  description = "GKE API endpoint."
  value       = module.gke.cluster_endpoint
}

output "cluster_ca_certificate" {
  description = "GKE cluster CA certificate (base64)."
  value       = module.gke.cluster_ca_certificate
  sensitive   = true
}

output "workload_identity_pool" {
  description = "Workload Identity pool for IRSA-equivalent GSA<->KSA bindings."
  value       = module.gke.workload_identity_pool
}

output "node_service_account_email" {
  description = "Service account email used by GKE nodes."
  value       = module.gke.node_service_account_email
}

output "cloudsql_instance_name" {
  description = "Cloud SQL instance name."
  value       = module.cloudsql.instance_name
}

output "cloudsql_connection_name" {
  description = "Cloud SQL instance connection name (project:region:instance)."
  value       = module.cloudsql.connection_name
}

output "cloudsql_private_ip" {
  description = "Cloud SQL private IP for app traffic."
  value       = module.cloudsql.private_ip
}

output "cloudsql_database_name" {
  description = "Initial ChainDB database name."
  value       = module.cloudsql.database_name
}

output "cloudsql_admin_user" {
  description = "Initial admin user created on the Cloud SQL instance."
  value       = module.cloudsql.admin_user
}

output "cloudsql_admin_password_secret_id" {
  description = "Secret Manager secret ID holding the Cloud SQL admin password."
  value       = module.cloudsql.admin_password_secret_id
}

output "cloudsql_proxy_service_account_email" {
  description = "GSA for the Cloud SQL Auth Proxy. Annotate the chart's serviceAccount.cloudSqlProxy with iam.gke.io/gcp-service-account = this value."
  value       = module.cloudsql.proxy_service_account_email
}

output "secrets" {
  description = "Secret Manager secret container IDs. Populate values outside Terraform."
  value       = module.secrets.secret_ids
}

output "eso_service_account_email" {
  description = "GSA for External Secrets Operator. Annotate externalSecrets.serviceAccount with iam.gke.io/gcp-service-account = this value."
  value       = module.secrets.eso_service_account_email
}

output "ingress_static_ip_name" {
  description = "Global static IP name to set on the chart's ingress.annotations[\"kubernetes.io/ingress.global-static-ip-name\"]."
  value       = var.ingress_static_ip_enabled ? google_compute_global_address.ingress[0].name : ""
}

output "ingress_static_ip_address" {
  description = "Allocated global IPv4 address for the Ingress. Customer DNS A record should point here."
  value       = var.ingress_static_ip_enabled ? google_compute_global_address.ingress[0].address : ""
}

output "ingress_cloud_armor_policy_name" {
  description = "Cloud Armor security policy name. Reference in a BackendConfig.spec.securityPolicy.name to attach to the GKE Ingress backend."
  value       = var.ingress_cloud_armor_enabled ? google_compute_security_policy.ingress[0].name : ""
}
