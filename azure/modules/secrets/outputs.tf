output "key_vault_id" {
  value = azurerm_key_vault.this.id
}

output "key_vault_name" {
  value = azurerm_key_vault.this.name
}

output "key_vault_uri" {
  description = "Vault URI. Set as externalSecrets.vaultUrl in the chart (provider=azurekv)."
  value       = azurerm_key_vault.this.vault_uri
}

output "secret_names" {
  description = "Map of placeholder secret container names created in the vault."
  value       = { for k, s in azurerm_key_vault_secret.placeholders : k => s.name }
}

output "eso_identity_client_id" {
  description = "Client ID of the ESO user-assigned identity. Set as the azure.workload.identity/client-id annotation on externalSecrets.serviceAccount."
  value       = azurerm_user_assigned_identity.eso.client_id
}

output "eso_identity_id" {
  value = azurerm_user_assigned_identity.eso.id
}
