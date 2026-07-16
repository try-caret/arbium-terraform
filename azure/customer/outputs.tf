output "resource_group_name" {
  description = "Dedicated Arbium resource group (arbium-<env>)."
  value       = azurerm_resource_group.this.name
}

output "vnet_id" {
  description = "Dedicated Arbium VNet ID."
  value       = module.network.vnet_id
}

output "nat_egress_ip" {
  description = "Stable NAT egress IP for the AKS nodes. Empty when NAT is disabled."
  value       = module.network.nat_public_ip
}

output "cluster_name" {
  description = "AKS cluster name."
  value       = module.aks.cluster_name
}

output "cluster_oidc_issuer_url" {
  description = "AKS OIDC issuer URL for Workload Identity federated credentials."
  value       = module.aks.oidc_issuer_url
}

output "node_resource_group" {
  description = "AKS-managed node resource group (MC_*)."
  value       = module.aks.node_resource_group
}

output "get_credentials_command" {
  description = "Command to fetch a kubeconfig for this cluster."
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.this.name} --name ${module.aks.cluster_name} --overwrite-existing"
}

output "postgres_fqdn" {
  description = "Private FQDN of the Postgres Flexible Server."
  value       = module.postgres.fqdn
}

output "postgres_database_name" {
  description = "Initial ChainDB database name."
  value       = module.postgres.database_name
}

output "database_url_secret_name" {
  description = "Key Vault secret holding DATABASE_URL. Map DATABASE_URL / SUPABASE_DB_URL to this in externalSecrets.dataMappings."
  value       = module.postgres.database_url_secret_name
}

output "key_vault_name" {
  description = "Key Vault name. Populate secret values out-of-band."
  value       = module.secrets.key_vault_name
}

output "key_vault_uri" {
  description = "Key Vault URI. Set as externalSecrets.vaultUrl in the chart (provider=azurekv)."
  value       = module.secrets.key_vault_uri
}

output "secrets" {
  description = "Placeholder Key Vault secret container names. Populate values outside Terraform."
  value       = module.secrets.secret_names
}

output "eso_identity_client_id" {
  description = "Client ID of the ESO user-assigned identity. Set as externalSecrets.serviceAccount.annotations[azure.workload.identity/client-id]."
  value       = module.secrets.eso_identity_client_id
}

output "ingress_ip" {
  description = "Static public IP for the ingress-nginx load balancer. Empty when disabled."
  value       = var.ingress_static_ip_enabled ? azurerm_public_ip.ingress[0].ip_address : ""
}

output "ingress_host" {
  description = "sslip.io hostname for the ingress (<ip>.sslip.io). Set as global.publicBaseUrl host + ingress.host in the chart."
  value       = var.ingress_static_ip_enabled ? "${azurerm_public_ip.ingress[0].ip_address}.sslip.io" : ""
}

output "capturelake_storage_account" {
  description = "CaptureLake Blob storage account name (null unless capturelake_enabled). The chart's DATA_PATH is az://capturelake/lake/ against this account."
  value       = var.capturelake_enabled ? azurerm_storage_account.capturelake[0].name : null
}

output "capturelake_kv_secret_names" {
  description = "Key Vault secret names to map in externalSecrets.dataMappings when CaptureLake is enabled (null otherwise)."
  value = var.capturelake_enabled ? {
    CAPTURELAKE_CATALOG_DSN                     = module.postgres.capturelake_catalog_dsn_secret_name
    CAPTURELAKE_DERIVED_DSN                     = module.postgres.capturelake_derived_dsn_secret_name
    CAPTURELAKE_AZURE_STORAGE_CONNECTION_STRING = azurerm_key_vault_secret.capturelake_storage_connection[0].name
  } : null
}
