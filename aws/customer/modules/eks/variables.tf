variable "name_prefix" { type = string }
variable "environment" { type = string }
variable "cluster_version" { type = string }
variable "vpc_id" { type = string }
variable "subnet_ids" { type = list(string) }
variable "cluster_endpoint_public_access" { type = bool }
variable "cluster_endpoint_private_access" { type = bool }
variable "general_node_instance_types" { type = list(string) }
variable "general_node_min_size" { type = number }
variable "general_node_desired_size" { type = number }
variable "general_node_max_size" { type = number }
variable "gpu_node_instance_types" { type = list(string) }
variable "gpu_node_ami_type" { type = string }
variable "gpu_node_min_size" { type = number }
variable "gpu_node_desired_size" { type = number }
variable "gpu_node_max_size" { type = number }
variable "lake_node_instance_types" { type = list(string) }
variable "lake_node_min_size" { type = number }
# 0 renders no node group at all — the opt-in switch for the whole thing.
variable "lake_node_desired_size" { type = number }
variable "lake_node_max_size" { type = number }
variable "tags" {
  type    = map(string)
  default = {}
}

variable "vpc_cni_warm_ip_target" {
  description = "Number of spare pod IPv4 addresses the VPC CNI attempts to keep per node. Larger reserves absorb pod-start bursts but consume more subnet addresses."
  type        = number
  default     = 2

  validation {
    condition     = var.vpc_cni_warm_ip_target == null ? false : var.vpc_cni_warm_ip_target >= 1 && floor(var.vpc_cni_warm_ip_target) == var.vpc_cni_warm_ip_target
    error_message = "vpc_cni_warm_ip_target must be a positive integer."
  }
}

variable "enable_node_launch_template" {
  description = "Attach a launch template to the managed node groups so tags propagate to the EC2 instances, EBS volumes, and primary ENIs (which EKS does NOT tag from node-group tags). Off by default; enabling it replaces existing node groups, so opt in per environment."
  type        = bool
  default     = false
}

variable "enable_network_policy" {
  type    = bool
  default = false
}

variable "enable_auto_mode" {
  description = "Turn on EKS Auto Mode with no built-in node pools (Kubernetes 1.36+ for Nitro sandboxes). It launches nodes only for NodePools added to the cluster."
  type        = bool
  default     = false
}
