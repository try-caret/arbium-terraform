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

variable "performance_insights_enabled" {
  description = "Turn on RDS Performance Insights for the Aurora instances, so a database stall leaves wait-event data to look at. Seven days of retention are free."
  type        = bool
  default     = true
}

variable "performance_insights_retention_period" {
  description = "Days Performance Insights keeps its data: 7 (free), 731, or a multiple of 31 from 31 to 713 (the last two are paid). Ignored when Performance Insights is off."
  type        = number
  default     = 7

  validation {
    condition     = contains([7, 731], var.performance_insights_retention_period) || (var.performance_insights_retention_period % 31 == 0 && var.performance_insights_retention_period >= 31 && var.performance_insights_retention_period <= 713)
    error_message = "performance_insights_retention_period must be 7, 731, or a multiple of 31 from 31 to 713."
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}
