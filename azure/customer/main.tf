locals {
  # Same tag key set as the AWS/GCP siblings. The per-stack identifier is
  # `deployment` = name_prefix-environment (=> arbium-dev), distinct from any
  # caller-supplied key so merge() only ever adds.
  tags = merge(
    {
      Project    = "Arbium"
      Component  = "ChainDB"
      deployment = "${var.name_prefix}-${var.environment}"
      ManagedBy  = "Terraform"
    },
    var.tags,
  )

  name = "${var.name_prefix}-${var.environment}"
}

# One resource group per cluster — arbium-dev. AKS creates its own managed
# node resource group (MC_*) alongside this one.
resource "azurerm_resource_group" "this" {
  name     = local.name
  location = var.location
  tags     = local.tags
}

module "network" {
  source = "../modules/network"

  resource_group_name  = azurerm_resource_group.this.name
  location             = azurerm_resource_group.this.location
  name_prefix          = var.name_prefix
  environment          = var.environment
  vnet_cidr            = var.vnet_cidr
  aks_subnet_cidr      = var.aks_subnet_cidr
  postgres_subnet_cidr = var.postgres_subnet_cidr
  enable_nat_gateway   = var.enable_nat_gateway
  tags                 = local.tags
}

module "aks" {
  source = "../modules/aks"

  resource_group_name          = azurerm_resource_group.this.name
  location                     = azurerm_resource_group.this.location
  name_prefix                  = var.name_prefix
  environment                  = var.environment
  tenant_id                    = var.tenant_id
  aks_subnet_id                = module.network.aks_subnet_id
  kubernetes_version           = var.kubernetes_version
  sku_tier                     = var.aks_sku_tier
  general_node_vm_size         = var.general_node_vm_size
  general_node_min_count       = var.general_node_min_count
  general_node_max_count       = var.general_node_max_count
  general_node_disk_size_gb    = var.general_node_disk_size_gb
  enable_nat_gateway_egress    = var.enable_nat_gateway
  grant_deployer_cluster_admin = var.grant_deployer_cluster_admin
  tags                         = local.tags
}

module "secrets" {
  source = "../modules/secrets"

  resource_group_name             = azurerm_resource_group.this.name
  location                        = azurerm_resource_group.this.location
  name_prefix                     = var.name_prefix
  environment                     = var.environment
  tenant_id                       = var.tenant_id
  secret_names                    = var.secret_names
  oidc_issuer_url                 = module.aks.oidc_issuer_url
  purge_protection_enabled        = var.key_vault_purge_protection
  eso_workload_identity_namespace = var.arbium_namespace
  tags                            = local.tags
}

module "postgres" {
  source = "../modules/postgres"

  resource_group_name   = azurerm_resource_group.this.name
  location              = azurerm_resource_group.this.location
  name_prefix           = var.name_prefix
  environment           = var.environment
  delegated_subnet_id   = module.network.postgres_subnet_id
  private_dns_zone_id   = module.network.postgres_private_dns_zone_id
  key_vault_id          = module.secrets.key_vault_id
  database_name         = var.database_name
  postgres_version      = var.postgres_version
  capturelake_enabled   = var.capturelake_enabled
  sku_name              = var.postgres_sku_name
  storage_mb            = var.postgres_storage_mb
  backup_retention_days = var.postgres_backup_retention_days

  # The private DNS zone must be VNet-linked before the flexible server binds to
  # it; the Key Vault secrets-officer grant must exist before it writes creds.
  depends_on = [module.network, module.secrets]
}

# Static ingress IP, created in the AKS-managed node resource group so the
# cluster's Standard load balancer can attach it with no extra RBAC. The chart's
# ingress-nginx service targets this IP; DNS/TLS uses <ip>.sslip.io. Azure
# analogue of the GCP reserved global address / AWS ALB.
resource "azurerm_public_ip" "ingress" {
  count = var.ingress_static_ip_enabled ? 1 : 0

  name                = "${local.name}-ingress"
  resource_group_name = module.aks.node_resource_group
  location            = azurerm_resource_group.this.location
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = local.tags
}
