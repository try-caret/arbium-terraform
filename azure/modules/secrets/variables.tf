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

variable "secret_names" {
  description = "Key Vault secret containers to create as placeholders. Values populated out-of-band."
  type        = set(string)
}

variable "oidc_issuer_url" {
  description = "AKS OIDC issuer URL for the ESO federated identity credential."
  type        = string
}

variable "purge_protection_enabled" {
  description = "Enable Key Vault purge protection. false for disposable dev environments so teardown is clean."
  type        = bool
  default     = false
}

variable "eso_workload_identity_namespace" {
  description = "Kubernetes namespace in which the ESO KSA lives."
  type        = string
  default     = "arbium"
}

variable "eso_workload_identity_ksa_name" {
  description = "KSA used by the ESO ClusterSecretStore. Must match externalSecrets.serviceAccount.name in the chart."
  type        = string
  default     = "eso"
}

variable "tags" {
  type    = map(string)
  default = {}
}
