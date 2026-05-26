output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr_block" {
  value = aws_vpc.this.cidr_block
}

output "private_subnet_ids" {
  value = [for subnet in aws_subnet.private : subnet.id]
}

output "public_subnet_ids" {
  value = [for subnet in aws_subnet.public : subnet.id]
}

output "private_route_table_ids" {
  value = [for rt in aws_route_table.private : rt.id]
}

output "vpc_endpoint_security_group_id" {
  value = try(aws_security_group.endpoints[0].id, null)
}
