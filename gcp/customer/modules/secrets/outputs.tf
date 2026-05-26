output "secret_ids" {
  value = { for k, s in google_secret_manager_secret.this : k => s.id }
}

output "secret_names" {
  value = { for k, s in google_secret_manager_secret.this : k => s.secret_id }
}

output "eso_service_account_email" {
  description = "Email of the GSA for External Secrets Operator. Set as iam.gke.io/gcp-service-account on externalSecrets.serviceAccount.annotations."
  value       = var.create_eso_sa ? google_service_account.eso[0].email : ""
}
