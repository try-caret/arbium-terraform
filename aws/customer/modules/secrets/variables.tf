variable "name_prefix" { type = string }
variable "environment" { type = string }
variable "secret_names" { type = set(string) }
variable "kms_key_id" {
  type    = string
  default = null
}
variable "tags" {
  type    = map(string)
  default = {}
}
