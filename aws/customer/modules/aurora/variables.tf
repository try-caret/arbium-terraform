variable "name_prefix" { type = string }
variable "environment" { type = string }
variable "vpc_id" { type = string }
variable "subnet_ids" { type = list(string) }
variable "eks_node_security_group_id" { type = string }

variable "database_name" {
  type    = string
  default = "chaindb"
}

variable "master_username" {
  type    = string
  default = "chaindb_admin"
}

variable "engine_version" {
  type    = string
  default = "16.13"
}

variable "serverless_min_acu" {
  type    = number
  default = 0.5
}

variable "serverless_max_acu" {
  type    = number
  default = 4
}

variable "instance_count" {
  type    = number
  default = 1
}

variable "backup_retention_days" {
  type    = number
  default = 7
}

variable "deletion_protection" {
  type    = bool
  default = false
}

variable "skip_final_snapshot" {
  type    = bool
  default = true
}

variable "apply_immediately" {
  type    = bool
  default = true
}

variable "enable_http_endpoint" {
  description = "Enable the RDS Data API (HTTPS+SigV4 query endpoint). Lets the AWS Console Query Editor and rds-data: SDK clients query the cluster without VPC connectivity. AWS named the toggle 'http' for the wire protocol AWS-side; cluster traffic remains TLS."
  type        = bool
  default     = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
