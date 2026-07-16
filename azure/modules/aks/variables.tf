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

variable "tenant_id" {
  type = string
}

variable "aks_subnet_id" {
  type = string
}

variable "kubernetes_version" {
  type    = string
  default = "1.31"
}

variable "sku_tier" {
  description = "Control-plane SKU tier. Free = no uptime SLA (cheapest, dev default). Standard for production HA."
  type        = string
  default     = "Free"
}

variable "general_node_vm_size" {
  description = "VM size for the single general node pool. Standard_D2as_v5 = 2 vCPU / 8 GiB, the cheapest viable general SKU for the ChainDB stack + CPU embedder."
  type        = string
  default     = "Standard_D2as_v5"
}

variable "general_node_min_count" {
  type    = number
  default = 1
}

variable "general_node_max_count" {
  type    = number
  default = 3
}

variable "general_node_disk_size_gb" {
  type    = number
  default = 64
}

variable "enable_nat_gateway_egress" {
  description = "Route node egress through the network module's user-assigned NAT gateway. Must match network module enable_nat_gateway."
  type        = bool
  default     = true
}

variable "grant_deployer_cluster_admin" {
  description = "Assign the deploying principal the 'Azure Kubernetes Service RBAC Cluster Admin' role so the helm/kubernetes providers can install addons in the same apply."
  type        = bool
  default     = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
