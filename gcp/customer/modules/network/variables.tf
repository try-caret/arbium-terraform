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

variable "labels" {
  type    = map(string)
  default = {}
}
