locals {
  ingress_certificate_validation_options = var.create_ingress_certificate ? {
    for option in aws_acm_certificate.ingress[0].domain_validation_options : option.domain_name => {
      name  = option.resource_record_name
      type  = option.resource_record_type
      value = option.resource_record_value
    }
  } : {}
}

resource "aws_acm_certificate" "ingress" {
  count = var.create_ingress_certificate ? 1 : 0

  domain_name       = var.ingress_domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true

    precondition {
      condition     = trimspace(var.ingress_domain_name) != ""
      error_message = "ingress_domain_name is required when create_ingress_certificate is true."
    }
  }

  tags = local.tags
}
