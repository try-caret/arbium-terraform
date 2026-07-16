locals {
  name = "${var.name_prefix}-${var.environment}"

  # Key Vault names are globally unique, 3-24 chars, alphanumeric + hyphens,
  # must start with a letter. A random suffix avoids collisions with the
  # 7-day soft-delete tombstone left by a prior apply/destroy cycle.
  vault_name = substr("kv-${var.name_prefix}-${var.environment}-${random_id.vault_suffix.hex}", 0, 24)
}

data "azurerm_client_config" "current" {}

resource "random_id" "vault_suffix" {
  byte_length = 2
}

# Key Vault — the Azure secret store, analogue of GCP Secret Manager and AWS
# Secrets Manager. RBAC data-plane authorization (not access policies) so ESO's
# federated identity gets least-privilege 'Key Vault Secrets User'.
resource "azurerm_key_vault" "this" {
  name                = local.vault_name
  resource_group_name = var.resource_group_name
  location            = var.location
  tenant_id           = var.tenant_id

  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = var.purge_protection_enabled
  soft_delete_retention_days = 7

  tags = var.tags
}

# The deploying principal needs data-plane write to create the placeholder
# secrets below and to let the postgres module write the generated DB creds.
resource "azurerm_role_assignment" "deployer_secrets_officer" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Placeholder secret containers. Values are intentionally NOT managed by
# Terraform (populated out-of-band by an operator), mirroring the GCP/AWS
# secrets modules that create empty containers. Azure has no empty-container
# concept, so we seed a placeholder value and ignore later drift.
resource "azurerm_key_vault_secret" "placeholders" {
  for_each = var.secret_names

  name         = "${local.name}-${each.value}"
  value        = "PLACEHOLDER-set-out-of-band"
  key_vault_id = azurerm_key_vault.this.id

  tags = var.tags

  lifecycle {
    ignore_changes = [value, content_type]
  }

  depends_on = [azurerm_role_assignment.deployer_secrets_officer]
}

# ─────────────────────────────────────────────────────────────────────────────
# External Secrets Operator identity. A user-assigned managed identity that the
# chart's `eso` KSA federates to via the AKS OIDC issuer (Workload Identity).
# Azure analogue of the GCP ESO GSA + Workload Identity binding and the AWS ESO
# IRSA role. Holds only 'Key Vault Secrets User' (read) on this vault.
# ─────────────────────────────────────────────────────────────────────────────
resource "azurerm_user_assigned_identity" "eso" {
  name                = "${local.name}-eso"
  resource_group_name = var.resource_group_name
  location            = var.location

  tags = var.tags
}

resource "azurerm_role_assignment" "eso_secrets_user" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.eso.principal_id
}

# Federate the AKS OIDC issuer + the `eso` KSA to the ESO identity. Subject must
# match system:serviceaccount:<chart-namespace>:<eso-KSA-name>.
resource "azurerm_federated_identity_credential" "eso" {
  name                = "${local.name}-eso"
  resource_group_name = var.resource_group_name
  parent_id           = azurerm_user_assigned_identity.eso.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = var.oidc_issuer_url
  subject             = "system:serviceaccount:${var.eso_workload_identity_namespace}:${var.eso_workload_identity_ksa_name}"
}
