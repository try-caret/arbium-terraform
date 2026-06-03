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
variable "tags" {
  type    = map(string)
  default = {}
}

variable "enable_node_launch_template" {
  description = "Attach a launch template to the managed node groups so tags propagate to the EC2 instances, EBS volumes, and primary ENIs (which EKS does NOT tag from node-group tags). Off by default; enabling it replaces existing node groups, so opt in per environment."
  type        = bool
  default     = false
}
