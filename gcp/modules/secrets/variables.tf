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
  default     = "eso"
}

variable "workload_identity_pool" {
  description = "The cluster's Workload Identity pool (the gke module's workload_identity_pool output, <project>.svc.id.goog). Taken from the cluster rather than built from the project id so the External Secrets Operator binding is ordered after the cluster that creates the pool."
  type        = string

  validation {
    condition     = can(regex("^[^\\[\\]/]+\\.svc\\.id\\.goog$", var.workload_identity_pool))
    error_message = "workload_identity_pool must be a Workload Identity pool name of the form <project>.svc.id.goog (the gke module's workload_identity_pool output)."
  }
}
