# Arbium customer Azure foundation example values.
# Copy this file to an environment-specific tfvars file and adjust values.
# Do not put secret values in tfvars.

subscription_id = "<azure-subscription-id>"
tenant_id       = "<azure-ad-tenant-id>"
# Pick a region where this subscription can provision BOTH AKS VM SKUs and
# Postgres Flexible Server. Restricted/sandbox subscriptions are commonly barred
# from Postgres in the busiest regions (e.g. eastus, eastus2 return
# LocationIsOfferRestricted); the dev deploy uses centralus for this reason.
location    = "centralus"
environment = "example"
name_prefix = "arbium"

# Network
vnet_cidr            = "10.80.0.0/16"
aks_subnet_cidr      = "10.80.0.0/20"
postgres_subnet_cidr = "10.80.16.0/24"
enable_nat_gateway   = true

# AKS — ONE general node pool, no GPU pool (embedder runs on CPU).
# Use a GA (non-LTS) Kubernetes minor: bare "1.31"/"1.32" resolve to
# LTS-only patches on AKS and are rejected (K8sVersionNotSupported).
kubernetes_version = "1.33"
aks_sku_tier       = "Free"
# v7 general-purpose SKU: v5 (Standard_D2as_v5) is not offered in some
# restricted subscriptions/regions. D2as_v7 is 2 vCPU / 8 GiB, same class.
general_node_vm_size   = "Standard_D2as_v7"
general_node_min_count = 1
general_node_max_count = 3

# Postgres Flexible Server — cheapest burstable tier.
database_name    = "chaindb"
postgres_version = "16"

# CaptureLake (DuckLake store/derive layer) — Blob storage account + container,
# capturelake/derived databases, and Key Vault secrets. Leave this off unless
# Arbium has supplied the matching CaptureLake chart values and database setup
# procedure; the standard install keeps application data in PostgreSQL.
capturelake_enabled            = false
postgres_sku_name              = "B_Standard_B1ms"
postgres_storage_mb            = 32768
postgres_backup_retention_days = 7

# Secret containers only. Populate values out-of-band in Key Vault. Add "scim"
# when SCIM is enabled; also add "admin-client-id" and "admin-client-secret"
# when enabling the fleet console. The database URL is created separately by
# the PostgreSQL module.
secret_names               = ["scheduler", "gemini", "enrollment", "jwt", "registry", "license"]
key_vault_purge_protection = false

# Ingress — static IP + <ip>.sslip.io host, TLS via cert-manager.
ingress_static_ip_enabled = true

tags = {
  Owner = "platform"
  Env   = "example"
}
