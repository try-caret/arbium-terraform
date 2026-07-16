variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "name_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "vnet_cidr" {
  type = string
}

variable "aks_subnet_cidr" {
  type = string
}

variable "postgres_subnet_cidr" {
  type = string
}

variable "enable_nat_gateway" {
  type    = bool
  default = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
