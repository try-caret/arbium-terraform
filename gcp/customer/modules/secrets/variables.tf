variable "project_id" {
  type = string
}

variable "name_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "secret_names" {
  type = set(string)
}

variable "labels" {
  type    = map(string)
  default = {}
}

variable "create_eso_sa" {
  description = "Create a GSA for External Secrets Operator with secretmanager.secretAccessor + Workload Identity binding."
  type        = bool
  default     = true
}

variable "eso_workload_identity_namespace" {
  description = "Kubernetes namespace in which the ESO KSA lives."
  type        = string
  default     = "arbium"
}

variable "eso_workload_identity_ksa_name" {
  description = "KSA used by the ESO ClusterSecretStore. Must match externalSecrets.serviceAccount.name in the chart."
  type        = string
  default     = "arbium-eso"
}
