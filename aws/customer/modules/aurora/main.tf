locals {
  name = "${var.name_prefix}-${var.environment}"
  # The parameter group family follows the engine's major, so a cluster still pinned to an older major keeps
  # its group while new installs get the module default. Changing a cluster's major is a separate, planned upgrade.
  pg_major = split(".", var.engine_version)[0]
}

resource "aws_db_subnet_group" "this" {
  name       = "${local.name}-aurora"
  subnet_ids = var.subnet_ids

  tags = merge(var.tags, {
    Name = "${local.name}-aurora"
  })
}

resource "aws_security_group" "aurora" {
  name        = "${local.name}-aurora"
  description = "Allow Arbium EKS nodes to reach Aurora"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Postgres from EKS nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.eks_node_security_group_id]
  }

  egress {
    description = "Aurora outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${local.name}-aurora"
  })
}

resource "aws_rds_cluster_parameter_group" "this" {
  name        = "${local.name}-aurora-pg${local.pg_major}"
  family      = "aurora-postgresql${local.pg_major}"
  description = "Arbium Aurora PostgreSQL ${local.pg_major} cluster parameters"

  parameter {
    name         = "shared_preload_libraries"
    value        = "pg_stat_statements"
    apply_method = "pending-reboot"
  }

  # Aurora PostgreSQL 17's default parameter group turns rds.force_ssl on (16's has it off), so after an upgrade
  # the cluster refuses every connection without TLS. Some DSNs connect without it (selfhost-staging uses
  # sslmode=disable), and that locked the staging app out after its rehearsal upgrade on 2026-11-25 (ARB-509).
  # Keep 16's behaviour on 17. Enforcing TLS is a separate change, once every client's DSN requires it.
  # Only on 17 and later, so the pg16 groups plan no change.
  dynamic "parameter" {
    for_each = tonumber(local.pg_major) >= 17 ? [1] : []
    content {
      name         = "rds.force_ssl"
      value        = "0"
      apply_method = "immediate"
    }
  }

  # The name carries the major, so a major upgrade creates the new group before the old one is released
  # (the cluster still uses the old one until ModifyDBCluster switches groups). The name stays fixed, not
  # name_prefix: name_prefix would give every existing cluster a new generated name (a replacement, not a
  # no-op). The one case a fixed name cannot cover is a later ForceNew edit within the same major (say the
  # description): create-before-destroy would then try to create a second group with the same name. Such an
  # edit needs a one-off name bump (e.g. a suffix) in the same change.
  lifecycle {
    create_before_destroy = true
  }

  tags = var.tags
}

resource "aws_rds_cluster" "this" {
  cluster_identifier              = "${local.name}-chaindb"
  engine                          = "aurora-postgresql"
  engine_version                  = var.engine_version
  allow_major_version_upgrade     = var.allow_major_version_upgrade ? true : null # null, not false: provider never reads it back, so false would show as a change on every existing cluster
  engine_mode                     = "provisioned"
  database_name                   = var.database_name
  master_username                 = var.master_username
  manage_master_user_password     = true
  db_subnet_group_name            = aws_db_subnet_group.this.name
  vpc_security_group_ids          = [aws_security_group.aurora.id]
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.this.name
  storage_encrypted               = true
  backup_retention_period         = var.backup_retention_days
  deletion_protection             = var.deletion_protection
  skip_final_snapshot             = var.skip_final_snapshot
  apply_immediately               = var.apply_immediately
  enable_http_endpoint            = var.enable_http_endpoint

  serverlessv2_scaling_configuration {
    min_capacity = var.serverless_min_acu
    max_capacity = var.serverless_max_acu
  }

  tags = merge(var.tags, {
    Name = "${local.name}-chaindb"
  })
}

resource "aws_rds_cluster_instance" "this" {
  count = var.instance_count

  identifier           = "${local.name}-chaindb-${count.index + 1}"
  cluster_identifier   = aws_rds_cluster.this.id
  instance_class       = "db.serverless"
  engine               = aws_rds_cluster.this.engine
  engine_version       = aws_rds_cluster.this.engine_version
  db_subnet_group_name = aws_db_subnet_group.this.name
  publicly_accessible  = false
  apply_immediately    = var.apply_immediately

  # No performance_insights_kms_key_id: new instances get the AWS-managed key, and an instance that
  # already has Performance Insights on keeps its own key (the attribute is optional and computed).
  performance_insights_enabled          = var.performance_insights_enabled
  performance_insights_retention_period = var.performance_insights_enabled ? var.performance_insights_retention_period : null

  tags = merge(var.tags, {
    Name = "${local.name}-chaindb-${count.index + 1}"
  })
}
