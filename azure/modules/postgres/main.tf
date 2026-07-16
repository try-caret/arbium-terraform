locals {
  name = "${var.name_prefix}-${var.environment}"
}

# Random instance suffix — mirrors the GCP cloudsql module. Azure retains
# deleted flexible-server names for a period, so repeated apply/destroy cycles
# need a fresh suffix to avoid name collisions.
resource "random_id" "instance_suffix" {
  byte_length = 2
}

# Generated admin password. Written to Key Vault (below); never surfaced as a
# module output, matching the GCP cloudsql module which keeps the password in
# Secret Manager rather than emitting it.
resource "random_password" "admin" {
  length           = 32
  special          = true
  override_special = "!@#%^&*()-_=+[]{}<>?"
}

# Postgres Flexible Server, private access (VNet-integrated). Analogue of the
# GCP Cloud SQL private instance and the AWS Aurora cluster in private subnets.
resource "azurerm_postgresql_flexible_server" "this" {
  name                = "${local.name}-pg-${random_id.instance_suffix.hex}"
  resource_group_name = var.resource_group_name
  location            = var.location
  version             = var.postgres_version

  # Private access: delegated subnet + private DNS zone. With these set the
  # server has no public endpoint.
  delegated_subnet_id           = var.delegated_subnet_id
  private_dns_zone_id           = var.private_dns_zone_id
  public_network_access_enabled = false

  administrator_login    = var.administrator_login
  administrator_password = random_password.admin.result

  sku_name   = var.sku_name
  storage_mb = var.storage_mb

  backup_retention_days        = var.backup_retention_days
  geo_redundant_backup_enabled = false
  zone                         = "1"

  tags = var.tags

  lifecycle {
    ignore_changes = [zone]
  }
}

resource "azurerm_postgresql_flexible_server_database" "chaindb" {
  name      = var.database_name
  server_id = azurerm_postgresql_flexible_server.this.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# Allowlist the extensions the ChainDB migrations create. Azure gates
# `CREATE EXTENSION` behind the server parameter `azure.extensions`; any
# extension not listed here fails with SQLSTATE 0A000. This is the Azure
# analogue of these extensions being available by default on Cloud SQL / RDS.
# The migration runner (Flyway initContainer) still issues the CREATE EXTENSION
# statements against the target database. Keep this in sync with every
# `CREATE EXTENSION` in ChainDB/supabase/migrations (currently: vector, pg_trgm,
# pgcrypto, unaccent, pg_stat_statements). pg_stat_statements is already in the
# server's default shared_preload_libraries (pg_cron,pg_stat_statements), so it
# only needs this allow-list entry to be CREATE-able — no preload change (and
# no restart) required.
resource "azurerm_postgresql_flexible_server_configuration" "extensions" {
  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "VECTOR,PG_TRGM,PGCRYPTO,UNACCENT,PG_STAT_STATEMENTS"
}

# Store the generated admin password AND the fully-assembled DATABASE_URL in
# Key Vault, so ESO (azurekv provider) can materialize them into the cluster
# without the value ever living in the chart values. Mirrors the GCP cloudsql
# module writing its admin password to its own Secret Manager secret (separate
# from the shared secret containers owned by the secrets module).
#
# The password is URL-encoded into the connection string so URL-hostile
# characters can't break the postgres client / Flyway parsing.
resource "azurerm_key_vault_secret" "admin_password" {
  name         = "${local.name}-postgres-admin"
  value        = random_password.admin.result
  key_vault_id = var.key_vault_id

  content_type = "password"
  tags         = var.tags
}

resource "azurerm_key_vault_secret" "database_url" {
  name = "${local.name}-database-url"
  value = format(
    "postgres://%s:%s@%s:5432/%s?sslmode=require",
    var.administrator_login,
    urlencode(random_password.admin.result),
    azurerm_postgresql_flexible_server.this.fqdn,
    var.database_name,
  )
  key_vault_id = var.key_vault_id

  content_type = "connection-string"
  tags         = var.tags
}

# CaptureLake — DuckLake catalog + derived store: dedicated databases on this
# same server. Mirrors the GCP sibling (google_sql_database pair on the shared
# Cloud SQL instance) and the AWS convention (separate databases on the existing
# Aurora — created out of band there only because the AWS provider has no
# in-cluster database resource). The assembled DSNs go to Key Vault exactly like
# DATABASE_URL above; URL form is required — CaptureLake's derived store accepts
# only postgres:// DSNs, and the DuckLake catalog attach takes them too.
# The `derived` extensions (vector, pg_trgm) are already in the azure.extensions
# allow-list; CREATE EXTENSION itself is a one-time out-of-band step (INSTALL.md).
resource "azurerm_postgresql_flexible_server_database" "capturelake" {
  count     = var.capturelake_enabled ? 1 : 0
  name      = "capturelake"
  server_id = azurerm_postgresql_flexible_server.this.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

resource "azurerm_postgresql_flexible_server_database" "derived" {
  count     = var.capturelake_enabled ? 1 : 0
  name      = "derived"
  server_id = azurerm_postgresql_flexible_server.this.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

resource "azurerm_key_vault_secret" "capturelake_catalog_dsn" {
  count = var.capturelake_enabled ? 1 : 0
  name  = "${local.name}-capturelake-catalog-dsn"
  value = format(
    "postgres://%s:%s@%s:5432/%s?sslmode=require",
    var.administrator_login,
    urlencode(random_password.admin.result),
    azurerm_postgresql_flexible_server.this.fqdn,
    azurerm_postgresql_flexible_server_database.capturelake[0].name,
  )
  key_vault_id = var.key_vault_id

  content_type = "connection-string"
  tags         = var.tags
}

resource "azurerm_key_vault_secret" "capturelake_derived_dsn" {
  count = var.capturelake_enabled ? 1 : 0
  name  = "${local.name}-capturelake-derived-dsn"
  value = format(
    "postgres://%s:%s@%s:5432/%s?sslmode=require",
    var.administrator_login,
    urlencode(random_password.admin.result),
    azurerm_postgresql_flexible_server.this.fqdn,
    azurerm_postgresql_flexible_server_database.derived[0].name,
  )
  key_vault_id = var.key_vault_id

  content_type = "connection-string"
  tags         = var.tags
}
