output "vpc_id" {
  description = "Dedicated Arbium VPC ID."
  value       = module.network.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs for EKS nodes and Aurora."
  value       = module.network.private_subnet_ids
}

output "public_subnet_ids" {
  description = "Public subnet IDs for internet-facing ALB/NAT, when enabled."
  value       = module.network.public_subnet_ids
}

output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API endpoint."
  value       = module.eks.cluster_endpoint
}

output "cluster_security_group_id" {
  description = "EKS cluster security group ID."
  value       = module.eks.cluster_security_group_id
}

output "cluster_oidc_provider_arn" {
  description = "OIDC provider ARN for IRSA roles."
  value       = module.eks.oidc_provider_arn
}

output "node_security_group_id" {
  description = "Security group used by EKS managed node groups."
  value       = module.eks.node_security_group_id
}

output "secrets" {
  description = "Secrets Manager secret container ARNs. Populate values outside Terraform."
  value       = module.secrets.secret_arns
}

output "aurora_cluster_endpoint" {
  description = "Aurora writer endpoint for ChainDB app traffic."
  value       = module.aurora.cluster_endpoint
}

output "aurora_database_name" {
  description = "Initial ChainDB database name."
  value       = module.aurora.database_name
}

output "aurora_master_user_secret_arn" {
  description = "RDS-managed master user secret ARN. Contains generated username/password JSON."
  value       = module.aurora.master_user_secret_arn
}

output "lb_controller_role_arn" {
  description = "IRSA role ARN for the AWS Load Balancer Controller. Empty when enable_lb_controller=false."
  value       = var.enable_lb_controller ? aws_iam_role.lbc[0].arn : ""
}

output "arbium_eso_role_arn" {
  description = "IRSA role ARN for the chart's `eso` KSA. Pass to externalSecrets.serviceAccount.annotations[eks.amazonaws.com/role-arn] in chart values."
  value       = var.enable_eso ? aws_iam_role.arbium_eso[0].arn : ""
}

output "capturelake_role_arn" {
  description = "IRSA role ARN for the chart's `chaindb-capturelake` KSA. Pass to serviceAccount.capturelake.annotations[eks.amazonaws.com/role-arn]. Empty when enable_capturelake=false."
  value       = var.enable_capturelake ? aws_iam_role.capturelake[0].arn : ""
}

output "capturelake_bucket" {
  description = "S3 bucket holding the CaptureLake DuckLake Parquet. Use in capturelake.env.DATA_PATH (s3://<bucket>/lake/). Empty when enable_capturelake=false."
  value       = var.enable_capturelake ? aws_s3_bucket.capturelake[0].bucket : ""
}

output "ingress_domain_name" {
  description = "Customer DNS name for the Arbium HTTPS ingress. Empty when create_ingress_certificate=false."
  value       = var.create_ingress_certificate ? var.ingress_domain_name : ""
}

output "ingress_certificate_arn" {
  description = "ACM certificate ARN for the Arbium ALB ingress. Create the validation DNS records from ingress_certificate_validation_records before using it for HTTPS."
  value       = var.create_ingress_certificate ? aws_acm_certificate.ingress[0].arn : ""
}

output "ingress_certificate_validation_records" {
  description = "DNS records required to validate the ACM certificate. Create these in the domain's DNS provider."
  value       = local.ingress_certificate_validation_options
}

output "ingress_certificate_status_check_command" {
  description = "AWS CLI command to check ACM certificate issuance status. Empty when create_ingress_certificate=false."
  value       = var.create_ingress_certificate ? "aws acm describe-certificate --region ${var.aws_region} --certificate-arn ${aws_acm_certificate.ingress[0].arn} --query 'Certificate.Status' --output text" : ""
}

output "helm_ingress_values_hint" {
  description = "YAML values snippet to enable Arbium AWS ALB ingress with the Terraform-managed certificate."
  value = var.create_ingress_certificate ? yamlencode({
    global = {
      publicBaseUrl = "https://${var.ingress_domain_name}"
    }
    ingress = {
      enabled        = true
      className      = "alb"
      host           = var.ingress_domain_name
      scheme         = "internet-facing"
      certificateArn = aws_acm_certificate.ingress[0].arn
    }
  }) : ""
}
