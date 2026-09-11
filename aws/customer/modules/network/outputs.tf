output "vpc_id" {
  value = local.vpc_id
}

output "vpc_cidr_block" {
  value = local.vpc_cidr
}

output "private_subnet_ids" {
  value = local.private_subnet_ids
}

output "public_subnet_ids" {
  value = local.public_subnet_ids
}

output "private_route_table_ids" {
  value = [for rt in aws_route_table.private : rt.id]
}

output "vpc_endpoint_security_group_id" {
  value = try(aws_security_group.endpoints[0].id, null)
}
