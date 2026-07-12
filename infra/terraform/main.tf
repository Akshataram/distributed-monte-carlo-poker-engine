terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  repo_root           = abspath("${path.module}/../..")
  terraform_build_dir = "${abspath(path.module)}/.build"
  name_prefix         = "${var.project_name}-${var.stage_name}"

  common_tags = merge(var.tags, {
    Project     = var.project_name
    Environment = var.stage_name
    ManagedBy   = "terraform"
    Application = "distributed-monte-carlo-poker-engine"
  })

  go_worker_source_files = sort(concat(
    tolist(fileset(local.repo_root, "cmd/worker-lambda/**/*.go")),
    tolist(fileset(local.repo_root, "internal/**/*.go")),
    tolist(fileset(local.repo_root, "go.mod"))
  ))

  go_status_source_files = sort(concat(
    tolist(fileset(local.repo_root, "cmd/status-lambda/**/*.go")),
    tolist(fileset(local.repo_root, "internal/**/*.go")),
    tolist(fileset(local.repo_root, "go.mod"))
  ))

  go_worker_source_hash = sha256(join("", [
    for file in local.go_worker_source_files : filesha256("${local.repo_root}/${file}")
  ]))

  go_status_source_hash = sha256(join("", [
    for file in local.go_status_source_files : filesha256("${local.repo_root}/${file}")
  ]))
}

# ==========================================
# Networking & Security Groups
# ==========================================

resource "aws_security_group" "lambda" {
  name        = "${local.name_prefix}-lambda-sg"
  description = "VPC Security Group for worker and status Lambda egress"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-lambda-sg"
  }
}

resource "aws_security_group" "redis" {
  name        = "${local.name_prefix}-redis-sg"
  description = "Redis ingress access control"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }

  tags = {
    Name = "${local.name_prefix}-redis-sg"
  }
}

# ==========================================
# ElastiCache Serverless Cache
# ==========================================

resource "aws_elasticache_serverless_cache" "aggregate" {
  engine             = var.redis_engine
  name               = "${local.name_prefix}-aggregate"
  security_group_ids = [aws_security_group.redis.id]
  subnet_ids         = var.subnet_ids
}

# ==========================================
# SQS Queues
# ==========================================

resource "aws_sqs_queue" "dlq" {
  name                      = "${local.name_prefix}-work-dlq"
  message_retention_seconds = 1209600 # 14 days
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "work" {
  name                       = "${local.name_prefix}-work"
  visibility_timeout_seconds = var.worker_queue_visibility_timeout_seconds
  message_retention_seconds  = 86400 # 1 day
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3
  })
}

# ==========================================
# DynamoDB Hand Sessions Table
# ==========================================

resource "aws_dynamodb_table" "sessions" {
  name                        = "${local.name_prefix}-hand-sessions"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "hand_id"
  deletion_protection_enabled = var.enable_deletion_protection

  attribute {
    name = "hand_id"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = var.enable_dynamodb_point_in_time_recovery
  }

  tags = {
    Name = "${local.name_prefix}-hand-sessions"
  }
}

# ==========================================
# CloudWatch Logs
# ==========================================

resource "aws_cloudwatch_log_group" "ingestion" {
  name              = "/aws/lambda/${local.name_prefix}-ingestion"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "worker" {
  name              = "/aws/lambda/${local.name_prefix}-worker"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "status" {
  name              = "/aws/lambda/${local.name_prefix}-status"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "api_access" {
  name              = "/aws/apigateway/${local.name_prefix}-http"
  retention_in_days = var.log_retention_days
}

# ==========================================
# IAM Roles & Policies
# ==========================================

# 1. Ingestion Lambda Role
resource "aws_iam_role" "ingestion" {
  name = "${local.name_prefix}-ingestion-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "ingestion" {
  name = "${local.name_prefix}-ingestion-policy"
  role = aws_iam_role.ingestion.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:*"
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem"
        ]
        Resource = aws_dynamodb_table.sessions.arn
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:SendMessageBatch"
        ]
        Resource = aws_sqs_queue.work.arn
      }
    ]
  })
}

# 2. Worker Lambda Role
resource "aws_iam_role" "worker" {
  name = "${local.name_prefix}-worker-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "worker" {
  name = "${local.name_prefix}-worker-policy"
  role = aws_iam_role.worker.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:*"
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:ChangeMessageVisibility"
        ]
        Resource = aws_sqs_queue.work.arn
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeSubnets",
          "ec2:DeleteNetworkInterface",
          "ec2:AssignPrivateIpAddresses",
          "ec2:UnassignPrivateIpAddresses"
        ]
        Resource = "*"
      }
    ]
  })
}

# 3. Status Lambda Role
resource "aws_iam_role" "status" {
  name = "${local.name_prefix}-status-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "status" {
  name = "${local.name_prefix}-status-policy"
  role = aws_iam_role.status.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeSubnets",
          "ec2:DeleteNetworkInterface",
          "ec2:AssignPrivateIpAddresses",
          "ec2:UnassignPrivateIpAddresses"
        ]
        Resource = "*"
      }
    ]
  })
}

# ==========================================
# Lambda Function Packages & Building
# ==========================================

resource "null_resource" "build_worker" {
  triggers = {
    build_version = "2"
    output_dir    = "${local.terraform_build_dir}/worker"
    source_hash   = local.go_worker_source_hash
  }

  provisioner "local-exec" {
    command = "mkdir -p ${local.terraform_build_dir}/worker && cd ${local.repo_root} && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o ${local.terraform_build_dir}/worker/bootstrap ./cmd/worker-lambda"
  }
}

data "archive_file" "worker" {
  type        = "zip"
  source_dir  = "${local.terraform_build_dir}/worker"
  output_path = "${local.terraform_build_dir}/worker.zip"
  depends_on  = [null_resource.build_worker]
}

resource "null_resource" "build_status" {
  triggers = {
    build_version = "2"
    output_dir    = "${local.terraform_build_dir}/status"
    source_hash   = local.go_status_source_hash
  }

  provisioner "local-exec" {
    command = "mkdir -p ${local.terraform_build_dir}/status && cd ${local.repo_root} && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o ${local.terraform_build_dir}/status/bootstrap ./cmd/status-lambda"
  }
}

data "archive_file" "status" {
  type        = "zip"
  source_dir  = "${local.terraform_build_dir}/status"
  output_path = "${local.terraform_build_dir}/status.zip"
  depends_on  = [null_resource.build_status]
}

data "archive_file" "ingestion" {
  type        = "zip"
  source_file = "${path.module}/../../cmd/ingestion-lambda/app.py"
  output_path = "${local.terraform_build_dir}/ingestion.zip"
}

# ==========================================
# Lambda Function Deployments
# ==========================================

# 1. Ingestion Lambda
resource "aws_lambda_function" "ingestion" {
  filename         = data.archive_file.ingestion.output_path
  source_code_hash = data.archive_file.ingestion.output_base64sha256
  function_name    = "${local.name_prefix}-ingestion"
  role             = aws_iam_role.ingestion.arn
  handler          = "app.handler"
  runtime          = var.lambda_runtime_python
  timeout          = 30
  memory_size      = 512

  environment {
    variables = {
      HAND_SESSIONS_TABLE          = aws_dynamodb_table.sessions.name
      WORK_QUEUE_URL               = aws_sqs_queue.work.url
      DEFAULT_TOTAL_ITERATIONS     = tostring(var.default_total_iterations)
      DEFAULT_ITERATIONS_PER_CHUNK = tostring(var.default_iterations_per_chunk)
      SESSION_TTL_SECONDS          = tostring(var.session_ttl_seconds)
    }
  }

  depends_on = [aws_cloudwatch_log_group.ingestion]
}

# 2. Worker Lambda
resource "aws_lambda_function" "worker" {
  filename         = data.archive_file.worker.output_path
  source_code_hash = data.archive_file.worker.output_base64sha256
  function_name    = "${local.name_prefix}-worker"
  role             = aws_iam_role.worker.arn
  handler          = "bootstrap"
  runtime          = "provided.al2023"
  architectures    = ["arm64"]
  timeout          = 120
  memory_size      = 1024

  environment {
    variables = {
      REDIS_ADDR            = "${aws_elasticache_serverless_cache.aggregate.endpoint[0].address}:6379"
      REDIS_TLS             = "true"
      AGGREGATE_TTL_SECONDS = tostring(var.aggregate_ttl_seconds)
    }
  }

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  reserved_concurrent_executions = var.worker_reserved_concurrency

  depends_on = [aws_cloudwatch_log_group.worker]
}

# 3. Status Lambda
resource "aws_lambda_function" "status" {
  filename         = data.archive_file.status.output_path
  source_code_hash = data.archive_file.status.output_base64sha256
  function_name    = "${local.name_prefix}-status"
  role             = aws_iam_role.status.arn
  handler          = "bootstrap"
  runtime          = "provided.al2023"
  architectures    = ["arm64"]
  timeout          = 10
  memory_size      = 512

  environment {
    variables = {
      REDIS_ADDR = "${aws_elasticache_serverless_cache.aggregate.endpoint[0].address}:6379"
      REDIS_TLS  = "true"
    }
  }

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  depends_on = [aws_cloudwatch_log_group.status]
}

# ==========================================
# Lambda Event Source Mappings
# ==========================================

resource "aws_lambda_event_source_mapping" "worker_sqs" {
  event_source_arn = aws_sqs_queue.work.arn
  function_name    = aws_lambda_function.worker.arn
  batch_size       = var.worker_batch_size

  function_response_types = ["ReportBatchItemFailures"]

  scaling_config {
    maximum_concurrency = var.worker_max_concurrency
  }
}

# ==========================================
# API Gateway HTTP API
# ==========================================

resource "aws_apigatewayv2_api" "http" {
  name          = "${local.name_prefix}-http"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      protocol       = "$context.protocol"
      responseLength = "$context.responseLength"
      integrationMs  = "$context.integrationLatency"
    })
  }
}

# Integrations
resource "aws_apigatewayv2_integration" "ingestion" {
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.ingestion.arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_integration" "status" {
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.status.arn
  payload_format_version = "2.0"
}

# Routes
resource "aws_apigatewayv2_route" "post_hands" {
  api_id    = aws_apigatewayv2_api.http.id
  route_key = "POST /hands"
  target    = "integrations/${aws_apigatewayv2_integration.ingestion.id}"
}

resource "aws_apigatewayv2_route" "get_status" {
  api_id    = aws_apigatewayv2_api.http.id
  route_key = "GET /hands/{hand_id}/results"
  target    = "integrations/${aws_apigatewayv2_integration.status.id}"
}

# Lambda Invoke Permissions
resource "aws_lambda_permission" "apigw_ingestion" {
  statement_id  = "${local.name_prefix}-apigw-invoke-ingestion"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ingestion.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/*/hands"
}

resource "aws_lambda_permission" "apigw_status" {
  statement_id  = "${local.name_prefix}-apigw-invoke-status"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.status.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/*/hands/*/results"
}

# ==========================================
# Operational Alarms
# ==========================================

resource "aws_cloudwatch_metric_alarm" "dlq_visible_messages" {
  count = var.enable_cloudwatch_alarms ? 1 : 0

  alarm_name          = "${local.name_prefix}-dlq-visible-messages"
  alarm_description   = "DLQ has messages; worker retries are failing and need inspection."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.dlq.name
  }
}

resource "aws_cloudwatch_metric_alarm" "worker_errors" {
  count = var.enable_cloudwatch_alarms ? 1 : 0

  alarm_name          = "${local.name_prefix}-worker-errors"
  alarm_description   = "Worker Lambda is returning errors."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.worker.function_name
  }
}

resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  count = var.enable_cloudwatch_alarms ? 1 : 0

  alarm_name          = "${local.name_prefix}-api-5xx"
  alarm_description   = "HTTP API is returning 5xx responses."
  namespace           = "AWS/ApiGateway"
  metric_name         = "5xx"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ApiId = aws_apigatewayv2_api.http.id
  }
}
