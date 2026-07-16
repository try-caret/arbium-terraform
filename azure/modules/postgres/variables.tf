variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "name_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "delegated_subnet_id" {
  type = string
}

variable "private_dns_zone_id" {
  type = string
}

variable "key_vault_id" {
  description = "Key Vault to write the generated admin password + assembled DATABASE_URL into. From the secrets module."
  type        = string
}

variable "database_name" {
  type    = string
  default = "chaindb"
}

variable "postgres_version" {
  type    = string
  default = "16"
}

variable "administrator_login" {
  type    = string
  default = "chaindb_admin"
}

variable "sku_name" {
  description = "Flexible Server SKU. B_Standard_B1ms = burstable 1 vCPU / 2 GiB, the cheapest viable tier."
  type        = string
  default     = "B_Standard_B1ms"
}

variable "storage_mb" {
  type    = number
  default = 32768
}

variable "backup_retention_days" {
  type    = number
  default = 7
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "capturelake_enabled" {
  description = "Create the dedicated `capturelake` (DuckLake catalog) + `derived` databases on this server and write their assembled DSNs to Key Vault. Set alongside capturelake.enabled=true in the chart values."
  type        = bool
  default     = false
}
