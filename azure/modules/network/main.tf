locals {
  name = "${var.name_prefix}-${var.environment}"
}

# Dedicated VNet for Arbium <env>. Mirrors the GCP module's dedicated VPC and
# the AWS module's dedicated VPC — one network per ChainDB cluster.
resource "azurerm_virtual_network" "this" {
  name                = local.name
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = [var.vnet_cidr]

  tags = var.tags
}

# AKS node + pod subnet. Azure CNI hands pod IPs out of this subnet, so it is
# sized generously (a /20 out of the /16 VNet) the same way the GCP pods
# secondary range is planned generously and the AWS private subnets are
# WARM_IP_TARGET-tuned.
resource "azurerm_subnet" "aks" {
  name                 = "${local.name}-aks-nodes"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.aks_subnet_cidr]
}

# Delegated subnet for the Postgres Flexible Server (VNet-integrated / private
# access). Delegation to Microsoft.DBforPostgreSQL/flexibleServers is required
# for private-access flexible servers — this is the Azure analogue of the GCP
# Private Service Access peering range and the AWS Aurora private subnets.
resource "azurerm_subnet" "postgres" {
  name                 = "${local.name}-postgres"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.postgres_subnet_cidr]

  delegation {
    name = "fs"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# NAT Gateway — controlled outbound egress from the private AKS nodes.
# Azure analogue of GCP Cloud NAT and the AWS NAT gateway. The AKS cluster is
# created with outbound_type=userAssignedNATGateway so all node egress routes
# through this gateway's static IP (stable egress address for allow-listing).
# ─────────────────────────────────────────────────────────────────────────────
resource "azurerm_public_ip" "nat" {
  count = var.enable_nat_gateway ? 1 : 0

  name                = "${local.name}-nat"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = var.tags
}

resource "azurerm_nat_gateway" "this" {
  count = var.enable_nat_gateway ? 1 : 0

  name                    = "${local.name}-nat"
  resource_group_name     = var.resource_group_name
  location                = var.location
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10

  tags = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "this" {
  count = var.enable_nat_gateway ? 1 : 0

  nat_gateway_id       = azurerm_nat_gateway.this[0].id
  public_ip_address_id = azurerm_public_ip.nat[0].id
}

resource "azurerm_subnet_nat_gateway_association" "aks" {
  count = var.enable_nat_gateway ? 1 : 0

  subnet_id      = azurerm_subnet.aks.id
  nat_gateway_id = azurerm_nat_gateway.this[0].id
}

# ─────────────────────────────────────────────────────────────────────────────
# Private DNS zone for the Postgres Flexible Server private endpoint. The zone
# is linked to the VNet so in-cluster clients resolve the server's
# <name>.privatelink.postgres.database.azure.com A record to its private IP.
# ─────────────────────────────────────────────────────────────────────────────
resource "azurerm_private_dns_zone" "postgres" {
  name                = "privatelink.postgres.database.azure.com"
  resource_group_name = var.resource_group_name

  tags = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                  = "${local.name}-postgres"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.postgres.name
  virtual_network_id    = azurerm_virtual_network.this.id
  registration_enabled  = false

  tags = var.tags
}
