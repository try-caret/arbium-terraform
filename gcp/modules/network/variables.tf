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

variable "subnet_cidr" {
  type = string
}

variable "pods_cidr" {
  type = string
}

variable "services_cidr" {
  type = string
}

variable "psa_cidr" {
  type = string
}

variable "enable_cloud_nat" {
  type    = bool
  default = true
}

variable "flow_sampling" {
  description = "Fraction of the nodes subnet's packets that VPC flow logs sample (0 to 1)."
  type        = number
  default     = 0.1

  validation {
    condition     = var.flow_sampling >= 0 && var.flow_sampling <= 1
    error_message = "flow_sampling is a fraction between 0 and 1."
  }
}

variable "labels" {
  type    = map(string)
  default = {}
}
