############################
# ECR: one immutable-tag repository per service
############################
resource "aws_ecr_repository" "svc" {
  for_each = var.services

  name                 = "${local.name}-${each.key}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = !local.is_prod

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.main.arn
  }
}

resource "aws_ecr_lifecycle_policy" "svc" {
  for_each = aws_ecr_repository.svc

  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the 30 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 30
      }
      action = { type = "expire" }
    }]
  })
}

############################
# Application Load Balancer
#   Locked to CloudFront twice: SG allows only CloudFront ranges, and the
#   listener rules require a secret header that only our distribution adds.
############################
resource "random_password" "origin_verify" {
  length  = 32
  special = false
}

resource "aws_lb" "app" {
  name               = substr("${local.name}-alb", 0, 32)
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  drop_invalid_header_fields = true
  enable_deletion_protection = local.is_prod
  idle_timeout               = 60
}

resource "aws_lb_listener" "https" {
  count = var.enable_custom_domain ? 1 : 0

  load_balancer_arn = aws_lb.app.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.alb[0].certificate_arn

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "Forbidden"
      status_code  = "403"
    }
  }
}

resource "aws_lb_listener" "http" {
  count = var.enable_custom_domain ? 0 : 1

  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "Forbidden"
      status_code  = "403"
    }
  }
}

locals {
  listener_arn = var.enable_custom_domain ? aws_lb_listener.https[0].arn : aws_lb_listener.http[0].arn
}

resource "aws_lb_target_group" "svc" {
  for_each = var.services

  name                 = substr("${local.name}-${each.key}", 0, 32)
  port                 = each.value.port
  protocol             = "HTTP"
  target_type          = "ip" # required for Fargate (awsvpc networking)
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 30

  health_check {
    path                = each.value.health_path
    matcher             = "200-399"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener_rule" "svc" {
  for_each = var.services

  listener_arn = local.listener_arn
  priority     = each.value.priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.svc[each.key].arn
  }

  condition {
    path_pattern {
      values = each.value.path_patterns
    }
  }

  condition {
    http_header {
      http_header_name = "X-Origin-Verify"
      values           = [random_password.origin_verify.result]
    }
  }
}

############################
# ECS cluster
############################
resource "aws_ecs_cluster" "main" {
  name = local.name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 1
  }
}

resource "aws_cloudwatch_log_group" "svc" {
  for_each = var.services

  name              = "/ecs/${local.name}/${each.key}"
  retention_in_days = var.log_retention_days
}

############################
# IAM
#   Execution role = what ECS itself needs to start a task (pull image, fetch secrets, write logs)
#   Task role      = what YOUR code may call at runtime (least privilege, one per service)
############################
data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "ecs_execution" {
  name               = "${local.name}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "ecs_execution_secrets" {
  name = "read-app-secrets"
  role = aws_iam_role.ecs_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = [
          aws_db_instance.orders.master_user_secret[0].secret_arn,
          aws_secretsmanager_secret.redis_auth.arn
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [aws_kms_key.main.arn]
      }
    ]
  })
}

resource "aws_iam_role" "task" {
  for_each = var.services

  name               = "${local.name}-${each.key}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy" "task_catalog" {
  name = "catalog-runtime"
  role = aws_iam_role.task["catalog"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject"]
      Resource = ["${aws_s3_bucket.this["media"].arn}/*"]
    }]
  })
}

resource "aws_iam_role_policy" "task_orders" {
  name = "orders-runtime"
  role = aws_iam_role.task["orders"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query"]
        Resource = [
          aws_dynamodb_table.cart.arn,
          aws_dynamodb_table.idempotency.arn
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = [aws_sns_topic.order_events.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource = [aws_kms_key.main.arn]
      }
    ]
  })
}

############################
# Task definitions and services
############################
resource "aws_ecs_task_definition" "svc" {
  for_each = var.services

  family                   = "${local.name}-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = each.value.cpu
  memory                   = each.value.memory
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.task[each.key].arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  container_definitions = jsonencode([{
    name      = each.key
    image     = lookup(var.container_images, each.key, var.placeholder_image)
    essential = true

    portMappings = [{
      containerPort = each.value.port
      protocol      = "tcp"
    }]

    environment = [
      { name = "ENVIRONMENT", value = var.environment },
      { name = "AWS_REGION", value = var.region },
      { name = "DB_HOST", value = aws_db_instance.orders.address },
      { name = "DB_PORT", value = "5432" },
      { name = "DB_NAME", value = "orders" },
      { name = "REDIS_HOST", value = aws_elasticache_replication_group.redis.primary_endpoint_address },
      { name = "REDIS_TLS", value = "true" },
      { name = "CART_TABLE", value = aws_dynamodb_table.cart.name },
      { name = "IDEMPOTENCY_TABLE", value = aws_dynamodb_table.idempotency.name },
      { name = "ORDER_EVENTS_TOPIC_ARN", value = aws_sns_topic.order_events.arn },
      { name = "MEDIA_BUCKET", value = aws_s3_bucket.this["media"].bucket }
    ]

    # Injected by ECS at start-up from Secrets Manager; never baked into the image.
    secrets = [
      { name = "DB_USERNAME", valueFrom = "${aws_db_instance.orders.master_user_secret[0].secret_arn}:username::" },
      { name = "DB_PASSWORD", valueFrom = "${aws_db_instance.orders.master_user_secret[0].secret_arn}:password::" },
      { name = "REDIS_AUTH_TOKEN", valueFrom = aws_secretsmanager_secret.redis_auth.arn }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.svc[each.key].name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = each.key
      }
    }
  }])
}

resource "aws_ecs_service" "svc" {
  for_each = var.services

  name            = each.key
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.svc[each.key].arn
  desired_count   = each.value.min_count

  # Prod runs on-demand Fargate. Non-prod uses Spot (about 70% cheaper, can be interrupted).
  capacity_provider_strategy {
    capacity_provider = local.is_prod ? "FARGATE" : "FARGATE_SPOT"
    weight            = 1
  }

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = 60

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = aws_subnet.app[*].id
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.svc[each.key].arn
    container_name   = each.key
    container_port   = each.value.port
  }

  # CI/CD registers new task definition revisions and autoscaling changes the
  # count. Terraform owns the infrastructure, the pipeline owns the release.
  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }

  depends_on = [
    aws_lb_listener_rule.svc,
    aws_ecs_cluster_capacity_providers.main
  ]
}

############################
# Auto scaling: target tracking on CPU and on requests per target
############################
resource "aws_appautoscaling_target" "svc" {
  for_each = var.services

  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.svc[each.key].name}"
  min_capacity       = each.value.min_count
  max_capacity       = each.value.max_count
}

resource "aws_appautoscaling_policy" "cpu" {
  for_each = var.services

  name               = "${each.key}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.svc[each.key].service_namespace
  scalable_dimension = aws_appautoscaling_target.svc[each.key].scalable_dimension
  resource_id        = aws_appautoscaling_target.svc[each.key].resource_id

  target_tracking_scaling_policy_configuration {
    target_value       = 60
    scale_out_cooldown = 60
    scale_in_cooldown  = 300

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

resource "aws_appautoscaling_policy" "requests" {
  for_each = var.services

  name               = "${each.key}-requests"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.svc[each.key].service_namespace
  scalable_dimension = aws_appautoscaling_target.svc[each.key].scalable_dimension
  resource_id        = aws_appautoscaling_target.svc[each.key].resource_id

  target_tracking_scaling_policy_configuration {
    target_value       = 500
    scale_out_cooldown = 60
    scale_in_cooldown  = 300

    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${aws_lb.app.arn_suffix}/${aws_lb_target_group.svc[each.key].arn_suffix}"
    }
  }
}

# FLASH-SALE PATTERN (uncomment and adjust): pre-warm capacity before a known
# traffic spike instead of waiting for reactive scaling.
#
# resource "aws_appautoscaling_scheduled_action" "orders_sale_prewarm" {
#   name               = "orders-sale-prewarm"
#   service_namespace  = aws_appautoscaling_target.svc["orders"].service_namespace
#   scalable_dimension = aws_appautoscaling_target.svc["orders"].scalable_dimension
#   resource_id        = aws_appautoscaling_target.svc["orders"].resource_id
#   schedule           = "cron(30 17 * * ? *)" # 23:00 IST (UTC+5:30)
#   timezone           = "UTC"
#
#   scalable_target_action {
#     min_capacity = 20
#     max_capacity = 60
#   }
# }
