############################
# RDS PostgreSQL: orders, payments, inventory (needs transactions and joins)
############################
resource "aws_db_subnet_group" "main" {
  name       = "${local.name}-db"
  subnet_ids = aws_subnet.data[*].id
}

resource "aws_db_parameter_group" "postgres" {
  name_prefix = "${local.name}-pg16-"
  family      = "postgres16"
  description = "Force TLS and log slow queries"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "500"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_role" "rds_monitoring" {
  name = "${local.name}-rds-monitoring"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_db_instance" "orders" {
  identifier = "${local.name}-orders"

  engine         = "postgres"
  engine_version = "16"
  instance_class = var.db_instance_class

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.main.arn

  db_name  = "orders"
  username = "appadmin"

  # RDS creates and rotates the master password in Secrets Manager.
  # It never appears in Terraform code or state.
  manage_master_user_password   = true
  master_user_secret_kms_key_id = aws_kms_key.main.arn

  multi_az               = var.db_multi_az
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.postgres.name
  publicly_accessible    = false

  backup_retention_period = local.is_prod ? 14 : 1
  backup_window           = "20:00-21:00"
  maintenance_window      = "sun:22:00-sun:23:00"
  copy_tags_to_snapshot   = true

  performance_insights_enabled    = var.db_performance_insights
  performance_insights_kms_key_id = var.db_performance_insights ? aws_kms_key.main.arn : null
  monitoring_interval             = 60
  monitoring_role_arn             = aws_iam_role.rds_monitoring.arn
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  auto_minor_version_upgrade = true
  deletion_protection        = local.is_prod
  skip_final_snapshot        = !local.is_prod
  final_snapshot_identifier  = local.is_prod ? "${local.name}-orders-final" : null
  apply_immediately          = !local.is_prod

  depends_on = [aws_iam_role_policy_attachment.rds_monitoring]
}

############################
# DynamoDB: carts (hot key-value) and idempotency keys
############################
resource "aws_dynamodb_table" "cart" {
  name         = "${local.name}-cart"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "user_id"
  range_key    = "sku"

  attribute {
    name = "user_id"
    type = "S"
  }

  attribute {
    name = "sku"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.main.arn
  }

  deletion_protection_enabled = local.is_prod
}

# Stops double charges and duplicate emails when a client or SQS retries.
resource "aws_dynamodb_table" "idempotency" {
  name         = "${local.name}-idempotency"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "idempotency_key"

  attribute {
    name = "idempotency_key"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.main.arn
  }

  deletion_protection_enabled = local.is_prod
}

############################
# Valkey (Redis-compatible): catalog cache and sessions
############################
resource "random_password" "redis_auth" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "redis_auth" {
  name                    = "${local.name}/redis-auth"
  kms_key_id              = aws_kms_key.main.arn
  recovery_window_in_days = local.is_prod ? 30 : 0
}

resource "aws_secretsmanager_secret_version" "redis_auth" {
  secret_id     = aws_secretsmanager_secret.redis_auth.id
  secret_string = random_password.redis_auth.result
}

resource "aws_elasticache_subnet_group" "redis" {
  name       = "${local.name}-redis"
  subnet_ids = aws_subnet.data[*].id
}

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id = "${local.name}-cache"
  description          = "Catalog cache and sessions"

  engine               = "valkey"
  engine_version       = "8.0"
  parameter_group_name = "default.valkey8"
  node_type            = var.cache_node_type
  num_cache_clusters   = var.cache_num_nodes
  port                 = 6379

  automatic_failover_enabled = var.cache_num_nodes > 1
  multi_az_enabled           = var.cache_num_nodes > 1

  subnet_group_name  = aws_elasticache_subnet_group.redis.name
  security_group_ids = [aws_security_group.redis.id]

  at_rest_encryption_enabled = true
  kms_key_id                 = aws_kms_key.main.arn
  transit_encryption_enabled = true
  auth_token                 = random_password.redis_auth.result

  snapshot_retention_limit = local.is_prod ? 7 : 0
  apply_immediately        = !local.is_prod
}

############################
# S3: frontend bundle and product media (both private, served via CloudFront)
############################
locals {
  buckets = toset(["frontend", "media"])
}

resource "aws_s3_bucket" "this" {
  for_each = local.buckets

  bucket        = "${local.name}-${each.key}-${data.aws_caller_identity.current.account_id}"
  force_destroy = !local.is_prod
}

resource "aws_s3_bucket_ownership_controls" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each = aws_s3_bucket.this

  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # SSE-S3: simplest with CloudFront OAC (see guide for SSE-KMS)
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  rule {
    id     = "housekeeping"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}
