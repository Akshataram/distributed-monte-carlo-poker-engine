output "api_endpoint" {
  description = "HTTP API Gateway endpoint URL"
  value       = aws_apigatewayv2_api.http.api_endpoint
}

output "hands_url" {
  description = "Endpoint URL to ingest new poker hands"
  value       = "${aws_apigatewayv2_api.http.api_endpoint}/hands"
}

output "result_url_template" {
  description = "Template URL to query simulation progress and equity results"
  value       = "${aws_apigatewayv2_api.http.api_endpoint}/hands/{hand_id}/results?board_version=0"
}

output "queue_url" {
  description = "SQS work queue URL"
  value       = aws_sqs_queue.work.url
}

output "queue_arn" {
  description = "SQS work queue ARN"
  value       = aws_sqs_queue.work.arn
}

output "dlq_url" {
  description = "SQS Dead Letter Queue URL"
  value       = aws_sqs_queue.dlq.url
}

output "redis_cache_name" {
  description = "Name of the ElastiCache serverless cache"
  value       = aws_elasticache_serverless_cache.aggregate.name
}

output "redis_addr" {
  description = "Network address endpoint of the Redis serverless cache"
  value       = "${aws_elasticache_serverless_cache.aggregate.endpoint[0].address}:6379"
}

output "worker_function_name" {
  description = "Name of the simulation worker Lambda function"
  value       = aws_lambda_function.worker.function_name
}

output "status_function_name" {
  description = "Name of the status retrieval Lambda function"
  value       = aws_lambda_function.status.function_name
}

output "ingestion_function_name" {
  description = "Name of the ingestion Lambda function"
  value       = aws_lambda_function.ingestion.function_name
}

output "table_name" {
  description = "DynamoDB session table name"
  value       = aws_dynamodb_table.sessions.name
}

output "api_id" {
  description = "HTTP API Gateway ID"
  value       = aws_apigatewayv2_api.http.id
}
