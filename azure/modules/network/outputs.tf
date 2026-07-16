output "vnet_id" {
  value = azurerm_virtual_network.this.id
}

output "vnet_name" {
  value = azurerm_virtual_network.this.name
}

output "aks_subnet_id" {
  value = azurerm_subnet.aks.id
}

output "postgres_subnet_id" {
  value = azurerm_subnet.postgres.id
}

output "postgres_private_dns_zone_id" {
  value = azurerm_private_dns_zone.postgres.id
}

output "postgres_private_dns_zone_name" {
  value = azurerm_private_dns_zone.postgres.name
}

output "nat_public_ip" {
  description = "Static egress IP for the NAT gateway. Empty when NAT is disabled."
  value       = var.enable_nat_gateway ? azurerm_public_ip.nat[0].ip_address : ""
}
