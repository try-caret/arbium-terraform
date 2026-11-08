output "cluster_identifier" {
  value = aws_rds_cluster.this.cluster_identifier
}

output "cluster_endpoint" {
  value = aws_rds_cluster.this.endpoint
}

output "reader_endpoint" {
  value = aws_rds_cluster.this.reader_endpoint
}

output "database_name" {
  value = aws_rds_cluster.this.database_name
}

output "master_user_secret_arn" {
  value = aws_rds_cluster.this.master_user_secret[0].secret_arn
}

output "security_group_id" {
  value = aws_security_group.aurora.id
}

output "performance_insights_enabled" {
  value = length(aws_rds_cluster_instance.this) > 0 ? aws_rds_cluster_instance.this[0].performance_insights_enabled : false
}

output "performance_insights_retention_period" {
  value = length(aws_rds_cluster_instance.this) > 0 ? aws_rds_cluster_instance.this[0].performance_insights_retention_period : null
}
