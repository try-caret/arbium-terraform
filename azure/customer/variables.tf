variable "subscription_id" {
  description = "Azure subscription ID to deploy the customer Arbium foundation into."
  type        = string
}

variable "tenant_id" {
  description = "Azure AD tenant ID (used for AKS AAD integration, Key Vault, and the azuread provider)."
  type        = string
}

variable "location" {
  description = "Azure region. All resources live here."
  type        = string
  default     = "eastus"
}

variable "name_prefix" {
  description = "External resource name prefix. Use arbium for customer-facing Azure/Kubernetes resources."
  type        = string
  default     = "arbium"
}

variable "environment" {
  description = "Environment name, e.g. dev, staging, prod. Combined with name_prefix into local.name (=> arbium-dev)."
  type        = string
  default     = "dev"
}

variable "tags" {
  description = "Additional tags applied to all supported resources."
  type        = map(string)
  default     = {}
}

# -----------------------------------------------------------------------------
# Network
# -----------------------------------------------------------------------------

variable "vnet_cidr" {
  description = "CIDR for the dedicated Arbium VNet."
  type        = string
  default     = "10.80.0.0/16"
}

variable "aks_subnet_cidr" {
  description = "Subnet CIDR for AKS nodes + pods. Azure CNI hands pod IPs out of this subnet, so size generously."
  type        = string
  default     = "10.80.0.0/20"
}

variable "postgres_subnet_cidr" {
  description = "Delegated subnet CIDR for the Postgres Flexible Server (private access)."
  type        = string
  default     = "10.80.16.0/24"
}

variable "enable_nat_gateway" {
  description = "Create a NAT gateway for controlled node egress (stable outbound IP). Cluster egress uses userAssignedNATGateway when true."
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# AKS
# -----------------------------------------------------------------------------

variable "kubernetes_version" {
  description = "AKS Kubernetes version."
  type        = string
  default     = "1.31"
}

variable "aks_sku_tier" {
  description = "AKS control-plane SKU tier. Free (no SLA) for dev; Standard for production."
  type        = string
  default     = "Free"
}

variable "general_node_vm_size" {
  description = "VM size for the single general node pool. NO GPU pool — the embedder runs on CPU."
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

variable "grant_deployer_cluster_admin" {
  description = "Assign the deploying principal cluster-admin (Azure RBAC) so the helm/kubernetes providers can install the addons in the same apply."
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# Postgres Flexible Server
# -----------------------------------------------------------------------------

variable "database_name" {
  description = "Initial ChainDB database name."
  type        = string
  default     = "chaindb"
}

variable "postgres_version" {
  description = "Postgres major version."
  type        = string
  default     = "16"
}

variable "postgres_sku_name" {
  description = "Flexible Server SKU. B_Standard_B1ms = cheapest burstable tier."
  type        = string
  default     = "B_Standard_B1ms"
}

variable "postgres_storage_mb" {
  description = "Flexible Server storage in MB."
  type        = number
  default     = 32768
}

variable "postgres_backup_retention_days" {
  description = "Automated backup retention in days."
  type        = number
  default     = 7
}

# -----------------------------------------------------------------------------
# Key Vault / Secrets
# -----------------------------------------------------------------------------

variable "secret_names" {
  description = "Key Vault secret containers to create as placeholders. Values are intentionally not managed by Terraform."
  type        = set(string)
  default = [
    "db",
    "scheduler",
    "scim",
    "gemini",
    "enrollment",
    "jwt",
    "registry",
    "license",
  ]
}

variable "key_vault_purge_protection" {
  description = "Enable Key Vault purge protection. Keep false for disposable dev environments so teardown is clean."
  type        = bool
  default     = false
}

variable "arbium_namespace" {
  description = "Kubernetes namespace the ChainDB chart installs into. Determines the ESO federated-identity subject and the default-ssl-certificate namespace."
  type        = string
  default     = "arbium"
}

# -----------------------------------------------------------------------------
# Ingress
# -----------------------------------------------------------------------------

variable "ingress_static_ip_enabled" {
  description = "Reserve a Standard static public IP for the ingress-nginx load balancer (in the AKS node RG). DNS/TLS uses <ip>.sslip.io."
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# Cluster addons — see addons.tf
# -----------------------------------------------------------------------------

variable "enable_eso" {
  description = "Install External Secrets Operator. Required when externalSecrets.enabled=true in the chart (provider=azurekv)."
  type        = bool
  default     = true
}

variable "eso_chart_version" {
  description = "Helm chart version for external-secrets. 2.0+ serves the v1 API the ChainDB chart uses."
  type        = string
  default     = "2.5.0"
}

variable "enable_ingress_nginx" {
  description = "Install ingress-nginx (one Standard LB). Required for the chart's Ingress (className=nginx) to become reachable."
  type        = bool
  default     = true
}

variable "ingress_nginx_chart_version" {
  description = "Helm chart version for ingress-nginx."
  type        = string
  default     = "4.11.3"
}

variable "enable_cert_manager" {
  description = "Install cert-manager for TLS on the sslip.io ingress host. Apply the ClusterIssuer + Certificate from customer/manifests after."
  type        = bool
  default     = true
}

variable "cert_manager_chart_version" {
  description = "Helm chart version for cert-manager (crds.enabled=true)."
  type        = string
  default     = "v1.16.2"
}

variable "enable_reloader" {
  description = "Install Stakater Reloader (rolls Deployments the ChainDB chart annotates when chaindb-runtime rotates)."
  type        = bool
  default     = true
}

variable "reloader_chart_version" {
  description = "Helm CHART version for stakater/reloader."
  type        = string
  default     = "2.2.12"
}

variable "capturelake_enabled" {
  description = "Provision the CaptureLake Blob storage account + container, the `capturelake`/`derived` databases on the Flexible Server, and their Key Vault secrets. Set alongside capturelake.enabled=true in the ChainDB chart values (INSTALL.md §10)."
  type        = bool
  default     = false
}
