output "instance_name" {
  value = google_sql_database_instance.this.name
}

output "connection_name" {
  value = google_sql_database_instance.this.connection_name
}

output "private_ip" {
  value = google_sql_database_instance.this.private_ip_address
}

output "database_name" {
  value = google_sql_database.chaindb.name
}

output "admin_user" {
  value = google_sql_user.admin.name
}

output "admin_password_secret_id" {
  value = google_secret_manager_secret.admin_password.secret_id
}

output "proxy_service_account_email" {
  description = "Email of the GSA for the Cloud SQL Auth Proxy. Set as iam.gke.io/gcp-service-account annotation on the proxy KSA."
  value       = var.create_proxy_sa ? google_service_account.cloudsql_proxy[0].email : ""
}
