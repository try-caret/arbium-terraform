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
  default     = "arbium-cloud-sql-proxy"
}
