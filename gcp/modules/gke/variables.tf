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

variable "subnet_id" {
  type = string
}

variable "pods_secondary_range_name" {
  type = string
}

variable "services_secondary_range_name" {
  type = string
}

variable "cluster_release_channel" {
  type    = string
  default = "REGULAR"
}

variable "cluster_endpoint_public_access" {
  type    = bool
  default = true
}

variable "cluster_endpoint_private_access" {
  type    = bool
  default = true
}

variable "master_authorized_networks" {
  type = list(object({
    cidr         = string
    display_name = string
  }))
  default = []
}

variable "general_node_machine_type" {
  type    = string
  default = "e2-standard-2"
}

variable "general_node_min_size" {
  type    = number
  default = 1
}

variable "general_node_max_size" {
  type    = number
  default = 3
}

variable "general_node_disk_size_gb" {
  type    = number
  default = 50
}

variable "gpu_node_enabled" {
  type    = bool
  default = true
}

variable "gpu_node_machine_type" {
  type    = string
  default = "g2-standard-4"
}

variable "gpu_node_accelerator_type" {
  type    = string
  default = "nvidia-l4"
}

variable "gpu_node_accelerator_count" {
  type    = number
  default = 1
}

variable "gpu_node_min_size" {
  type    = number
  default = 0
}

variable "gpu_node_max_size" {
  type    = number
  default = 1
}

variable "gpu_node_disk_size_gb" {
  type    = number
  default = 100
}

variable "labels" {
  type    = map(string)
  default = {}
}
