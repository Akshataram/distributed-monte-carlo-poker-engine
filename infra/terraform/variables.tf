variable "aws_region" {
  description = "AWS region to deploy resources into"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Name of the project prefixing all resource names"
  type        = string
  default     = "poker-ev"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,24}$", var.project_name))
    error_message = "project_name must be 2-25 lowercase letters, numbers, or hyphens, beginning with a letter."
  }
}

variable "stage_name" {
  description = "Environment stage (e.g. dev, staging, prod)"
  type        = string
  default     = "dev"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,16}$", var.stage_name))
    error_message = "stage_name must be 2-17 lowercase letters, numbers, or hyphens, beginning with a letter."
  }
}

variable "vpc_id" {
  description = "VPC ID where the Lambda functions and Redis serverless cache should run"
  type        = string
}

variable "subnet_ids" {
  description = "List of private subnet IDs for Lambda VPC attachment and ElastiCache"
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "Provide at least two subnet IDs for high availability."
  }
}

variable "redis_engine" {
  description = "Cache engine, either redis or valkey"
  type        = string
  default     = "redis"

  validation {
    condition     = contains(["redis", "valkey"], var.redis_engine)
    error_message = "redis_engine must be either redis or valkey."
  }
}

variable "worker_max_concurrency" {
  description = "Maximum concurrency limit for the SQS event source mapping"
  type        = number
  default     = 100
}

variable "worker_reserved_concurrency" {
  description = "Optionally reserve a specific concurrency quota for the worker Lambda"
  type        = number
  default     = null
}

variable "worker_batch_size" {
  description = "Number of SQS messages the worker Lambda processes in a single batch"
  type        = number
  default     = 5
}

variable "worker_queue_visibility_timeout_seconds" {
  description = "SQS visibility timeout. Keep this longer than worker Lambda timeout."
  type        = number
  default     = 180
}

variable "aggregate_ttl_seconds" {
  description = "TTL for Redis aggregate keys and processed idempotency keys"
  type        = number
  default     = 86400
}

variable "default_total_iterations" {
  description = "Default total simulations to run if not specified in POST body"
  type        = number
  default     = 1000000
}

variable "default_iterations_per_chunk" {
  description = "Default simulations run by a single worker chunk"
  type        = number
  default     = 10000
}

variable "session_ttl_seconds" {
  description = "TTL for DynamoDB hand session metadata"
  type        = number
  default     = 86400
}

variable "lambda_runtime_python" {
  description = "Python Lambda runtime to use for ingestion"
  type        = string
  default     = "python3.12"
}

variable "log_retention_days" {
  description = "CloudWatch log retention period for Lambda and API Gateway logs"
  type        = number
  default     = 14
}

variable "enable_cloudwatch_alarms" {
  description = "Create CloudWatch alarms for DLQ messages, worker errors, and API 5xx responses"
  type        = bool
  default     = true
}

variable "enable_dynamodb_point_in_time_recovery" {
  description = "Enable DynamoDB point-in-time recovery for hand session metadata"
  type        = bool
  default     = true
}

variable "enable_deletion_protection" {
  description = "Enable deletion protection on stateful AWS resources that support it"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Additional tags applied to AWS resources"
  type        = map(string)
  default     = {}
}
