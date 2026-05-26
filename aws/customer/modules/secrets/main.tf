locals {
  name = "${var.name_prefix}/${var.environment}"
}

resource "aws_secretsmanager_secret" "this" {
  for_each = var.secret_names

  name                    = "${local.name}/${each.key}"
  description             = "Arbium ${var.environment} ${each.key} secret container. Populate value outside Terraform."
  kms_key_id              = var.kms_key_id
  recovery_window_in_days = 30

  tags = merge(var.tags, {
    Name = "${local.name}/${each.key}"
  })
}
