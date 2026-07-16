# CaptureLake — Azure Blob data store for the `chaindb-capturelake` workload
#
# CaptureLake (the chart's capturelake Deployment + ten-minute maintenance/
# derive CronJobs) stores its DuckLake Parquet in a Blob container. DuckDB's
# `azure` extension authenticates with the storage-account connection string,
# delivered Key Vault -> ESO -> runtime Secret like every other runtime
# credential here (the Azure analogue of the GCS HMAC key pair on GCP; AWS uses
# IRSA instead). The DuckLake catalog + derived store are dedicated databases on
# the existing Flexible Server, created by the postgres module (same flag).
# Gated behind capturelake_enabled so installs without CaptureLake are
# unaffected — the chart's capturelake.enabled defaults to false to match.

# Storage-account names are globally unique, 3-24 chars, lowercase alphanumeric
# only — hence the stripped prefix + random suffix (same reasoning as the
# flexible server's instance suffix).
resource "random_id" "capturelake_storage_suffix" {
  count       = var.capturelake_enabled ? 1 : 0
  byte_length = 2
}

resource "azurerm_storage_account" "capturelake" {
  count = var.capturelake_enabled ? 1 : 0

  name                            = "${substr(replace(local.name, "-", ""), 0, 16)}lake${random_id.capturelake_storage_suffix[0].hex}"
  resource_group_name             = azurerm_resource_group.this.name
  location                        = azurerm_resource_group.this.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false

  tags = local.tags
}

resource "azurerm_storage_container" "capturelake" {
  count                 = var.capturelake_enabled ? 1 : 0
  name                  = "capturelake"
  storage_account_id    = azurerm_storage_account.capturelake[0].id
  container_access_type = "private"
}

resource "azurerm_key_vault_secret" "capturelake_storage_connection" {
  count        = var.capturelake_enabled ? 1 : 0
  name         = "${local.name}-capturelake-storage-connection"
  value        = azurerm_storage_account.capturelake[0].primary_connection_string
  key_vault_id = module.secrets.key_vault_id

  content_type = "connection-string"
  tags         = local.tags
}
