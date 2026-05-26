variable "name_prefix" { type = string }
variable "environment" { type = string }
variable "vpc_cidr" { type = string }
variable "availability_zones" { type = list(string) }
variable "private_subnet_cidrs" { type = list(string) }
variable "public_subnet_cidrs" { type = list(string) }
variable "create_public_subnets" { type = bool }
variable "enable_nat_gateway" { type = bool }
variable "single_nat_gateway" { type = bool }
variable "enable_vpc_endpoints" { type = bool }
variable "interface_endpoint_services" { type = set(string) }
variable "tags" {
  type    = map(string)
  default = {}
}
