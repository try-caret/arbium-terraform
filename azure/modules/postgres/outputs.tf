output "server_name" {
  value = azurerm_postgresql_flexible_server.this.name
}

output "fqdn" {
  description = "Private FQDN of the flexible server (resolves via the linked private DNS zone)."
  value       = azurerm_postgresql_flexible_server.this.fqdn
}

output "database_name" {
  value = azurerm_postgresql_flexible_server_database.chaindb.name
}

output "administrator_login" {
  value = var.administrator_login
}

output "admin_password_secret_name" {
  description = "Key Vault secret name holding the generated admin password."
  value       = azurerm_key_vault_secret.admin_password.name
}

output "database_url_secret_name" {
  description = "Key Vault secret name holding the assembled DATABASE_URL. Map DATABASE_URL / SUPABASE_DB_URL to this in the chart's externalSecrets.dataMappings."
  value       = azurerm_key_vault_secret.database_url.name
}

output "capturelake_catalog_dsn_secret_name" {
  description = "Key Vault secret name holding the CaptureLake catalog DSN (null unless capturelake_enabled). Map CAPTURELAKE_CATALOG_DSN to it in externalSecrets.dataMappings."
  value       = var.capturelake_enabled ? azurerm_key_vault_secret.capturelake_catalog_dsn[0].name : null
}

output "capturelake_derived_dsn_secret_name" {
  description = "Key Vault secret name holding the CaptureLake derived-store DSN (null unless capturelake_enabled). Map CAPTURELAKE_DERIVED_DSN to it in externalSecrets.dataMappings."
  value       = var.capturelake_enabled ? azurerm_key_vault_secret.capturelake_derived_dsn[0].name : null
}
