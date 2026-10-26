variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "name_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "network_id" {
  type = string
}

variable "database_name" {
  type = string
}

variable "database_version" {
  type    = string
  default = "POSTGRES_16"
}

variable "tier" {
  type = string
}

variable "edition" {
  type    = string
  default = "ENTERPRISE"
}

variable "disk_size_gb" {
  type    = number
  default = 20
}

variable "disk_autoresize_limit_gb" {
  type    = number
  default = 200
}

variable "availability_type" {
  type    = string
  default = "ZONAL"
}

variable "backup_retention_days" {
  type    = number
  default = 7
}

variable "deletion_protection" {
  type    = bool
  default = true
}

variable "instance_deletion_protection_enabled" {
  description = "Cloud SQL's own deletion protection (settings.deletion_protection_enabled): the API refuses to delete the instance until it is switched off. Independent of deletion_protection above, which is Terraform's guard checked against state."
  type        = bool
  default     = false
}

variable "retain_backups_on_delete" {
  description = "Keep the automated backups after the instance is deleted (settings.retain_backups_on_delete)."
  type        = bool
  default     = false
}

variable "create_admin_user" {
  description = "Create a Terraform-managed admin SQL user and generated password secret version. Disable for hosted environments where operators manage DB credentials outside Terraform state."
  type        = bool
  default     = true
}

variable "labels" {
  type    = map(string)
  default = {}
}

variable "create_proxy_sa" {
  description = "Create a dedicated GSA for the Cloud SQL Auth Proxy. Disable to manage that GSA elsewhere."
  type        = bool
  default     = true
}

variable "proxy_workload_identity_namespace" {
  description = "Kubernetes namespace in which the Cloud SQL Auth Proxy KSA lives. Used to construct the Workload Identity principal."
  type        = string
  default     = "arbium"
}

variable "proxy_workload_identity_ksa_name" {
  description = "Kubernetes service account name used by the Cloud SQL Auth Proxy pod. Must match the chart's serviceAccount.cloudSqlProxy.name."
  type        = string
  default     = "cloud-sql-proxy"
}

variable "workload_identity_pool" {
  description = "The cluster's Workload Identity pool (the gke module's workload_identity_pool output, <project>.svc.id.goog). Taken from the cluster rather than built from the project id so the proxy binding is ordered after the cluster that creates the pool."
  type        = string

  validation {
    condition     = can(regex("^[^\\[\\]/]+\\.svc\\.id\\.goog$", var.workload_identity_pool))
    error_message = "workload_identity_pool must be a Workload Identity pool name of the form <project>.svc.id.goog (the gke module's workload_identity_pool output)."
  }
}
