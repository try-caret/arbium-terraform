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

# DNS ownership is independent of network ownership. This always creates a NEW
# public zone; it neither adopts the old zone nor changes its parent delegation.
resource "aws_route53_zone" "ingress" {
  count         = var.create_public_hosted_zone ? 1 : 0
  name          = var.ingress_domain_name
  force_destroy = false
  tags          = local.tags

  lifecycle {
    precondition {
      condition     = var.create_ingress_certificate && trimspace(var.ingress_domain_name) != ""
      error_message = "create_public_hosted_zone requires create_ingress_certificate and ingress_domain_name."
    }
  }
}

resource "aws_route53_record" "ingress_validation" {
  # This chart requests one domain. A count known before ACM issues its token
  # avoids using computed domain_validation_options as for_each keys.
  count   = var.create_public_hosted_zone && var.create_ingress_certificate ? 1 : 0
  zone_id = aws_route53_zone.ingress[0].zone_id
  name    = one(values(local.ingress_certificate_validation_options)).name
  type    = one(values(local.ingress_certificate_validation_options)).type
  records = [one(values(local.ingress_certificate_validation_options)).value]
  ttl     = 300
}

# No aws_acm_certificate_validation waiter here: the new zone may not yet be
# delegated. The operator publishes the token in the OLD authoritative zone,
# waits for ISSUED, installs Helm, then supplies the controller-created ALB.
resource "aws_route53_record" "ingress_alias" {
  count   = var.ingress_alb == null ? 0 : 1
  zone_id = one(aws_route53_zone.ingress[*].zone_id)
  name    = var.ingress_domain_name
  type    = "A"

  alias {
    name                   = var.ingress_alb.dns_name
    zone_id                = var.ingress_alb.zone_id
    evaluate_target_health = true
  }

  lifecycle {
    precondition {
      condition     = var.create_public_hosted_zone
      error_message = "ingress_alb requires create_public_hosted_zone; this stack must not write an alias into an externally owned zone."
    }
  }
}
