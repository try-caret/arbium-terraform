locals {
  name = "${var.name_prefix}-${var.environment}"
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
  name        = "${local.name}-aurora-pg16"
  family      = "aurora-postgresql16"
  description = "Arbium Aurora PostgreSQL 16 cluster parameters"

  parameter {
    name         = "shared_preload_libraries"
    value        = "pg_stat_statements"
    apply_method = "pending-reboot"
  }

  tags = var.tags
}

resource "aws_rds_cluster" "this" {
  cluster_identifier              = "${local.name}-chaindb"
  engine                          = "aurora-postgresql"
  engine_version                  = var.engine_version
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

  tags = merge(var.tags, {
    Name = "${local.name}-chaindb-${count.index + 1}"
  })
}
