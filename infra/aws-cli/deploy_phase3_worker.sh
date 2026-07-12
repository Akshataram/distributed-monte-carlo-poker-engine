#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/phase3"
mkdir -p "$BUILD_DIR"

AWS_REGION="${AWS_REGION:-us-east-1}"
PROJECT_NAME="${PROJECT_NAME:-poker-ev}"
STAGE_NAME="${STAGE_NAME:-dev}"
VPC_ID="${VPC_ID:-}"
SUBNET_IDS="${SUBNET_IDS:-}"
LAMBDA_SECURITY_GROUP_IDS="${LAMBDA_SECURITY_GROUP_IDS:-}"
REDIS_SECURITY_GROUP_IDS="${REDIS_SECURITY_GROUP_IDS:-}"
REDIS_ENGINE="${REDIS_ENGINE:-redis}"
WORKER_MAX_CONCURRENCY="${WORKER_MAX_CONCURRENCY:-100}"
WORKER_RESERVED_CONCURRENCY="${WORKER_RESERVED_CONCURRENCY:-}"
WORKER_BATCH_SIZE="${WORKER_BATCH_SIZE:-5}"
AGGREGATE_TTL_SECONDS="${AGGREGATE_TTL_SECONDS:-86400}"

QUEUE_NAME="$PROJECT_NAME-$STAGE_NAME-work"
DLQ_NAME="$PROJECT_NAME-$STAGE_NAME-work-dlq"
WORKER_ROLE_NAME="$PROJECT_NAME-$STAGE_NAME-worker-role"
WORKER_FUNCTION_NAME="$PROJECT_NAME-$STAGE_NAME-worker"
REDIS_CACHE_NAME="$PROJECT_NAME-$STAGE_NAME-aggregate"
ZIP_PATH="$BUILD_DIR/worker.zip"

if [[ -z "$VPC_ID" ]]; then
  echo "VPC_ID is required because Lambda must reach ElastiCache inside a VPC." >&2
  exit 1
fi
if [[ -z "$SUBNET_IDS" ]]; then
  echo "SUBNET_IDS is required as a comma-separated list, e.g. subnet-a,subnet-b." >&2
  exit 1
fi
IFS=',' read -r -a SUBNET_ID_ARRAY <<< "$SUBNET_IDS"

echo "Deploying Phase 3 worker stack to region $AWS_REGION"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text --region "$AWS_REGION")"

echo "Creating or locating SQS queues"
DLQ_URL="$(aws sqs create-queue \
  --queue-name "$DLQ_NAME" \
  --attributes MessageRetentionPeriod=1209600 \
  --query QueueUrl \
  --output text \
  --region "$AWS_REGION")"
DLQ_ARN="$(aws sqs get-queue-attributes \
  --queue-url "$DLQ_URL" \
  --attribute-names QueueArn \
  --query 'Attributes.QueueArn' \
  --output text \
  --region "$AWS_REGION")"

cat > "$BUILD_DIR/work-queue-attributes.json" <<JSON
{
  "VisibilityTimeout": "180",
  "MessageRetentionPeriod": "86400",
  "RedrivePolicy": "{\"deadLetterTargetArn\":\"$DLQ_ARN\",\"maxReceiveCount\":\"3\"}"
}
JSON

QUEUE_URL="$(aws sqs create-queue \
  --queue-name "$QUEUE_NAME" \
  --attributes "file://$BUILD_DIR/work-queue-attributes.json" \
  --query QueueUrl \
  --output text \
  --region "$AWS_REGION")"
QUEUE_ARN="$(aws sqs get-queue-attributes \
  --queue-url "$QUEUE_URL" \
  --attribute-names QueueArn \
  --query 'Attributes.QueueArn' \
  --output text \
  --region "$AWS_REGION")"

if [[ -z "$REDIS_SECURITY_GROUP_IDS" ]]; then
  echo "Creating Redis security group"
  REDIS_SG_ID="$(aws ec2 create-security-group \
    --group-name "$PROJECT_NAME-$STAGE_NAME-redis-sg" \
    --description "Redis aggregation access for $PROJECT_NAME $STAGE_NAME" \
    --vpc-id "$VPC_ID" \
    --query GroupId \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || aws ec2 describe-security-groups \
      --filters "Name=group-name,Values=$PROJECT_NAME-$STAGE_NAME-redis-sg" "Name=vpc-id,Values=$VPC_ID" \
      --query 'SecurityGroups[0].GroupId' \
      --output text \
      --region "$AWS_REGION")"
  REDIS_SECURITY_GROUP_IDS="$REDIS_SG_ID"
else
  REDIS_SG_ID="${REDIS_SECURITY_GROUP_IDS%%,*}"
fi
IFS=',' read -r -a REDIS_SECURITY_GROUP_ID_ARRAY <<< "$REDIS_SECURITY_GROUP_IDS"

if [[ -z "$LAMBDA_SECURITY_GROUP_IDS" ]]; then
  echo "Creating Lambda security group"
  LAMBDA_SG_ID="$(aws ec2 create-security-group \
    --group-name "$PROJECT_NAME-$STAGE_NAME-worker-lambda-sg" \
    --description "Worker Lambda egress for $PROJECT_NAME $STAGE_NAME" \
    --vpc-id "$VPC_ID" \
    --query GroupId \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || aws ec2 describe-security-groups \
      --filters "Name=group-name,Values=$PROJECT_NAME-$STAGE_NAME-worker-lambda-sg" "Name=vpc-id,Values=$VPC_ID" \
      --query 'SecurityGroups[0].GroupId' \
      --output text \
      --region "$AWS_REGION")"
  LAMBDA_SECURITY_GROUP_IDS="$LAMBDA_SG_ID"
else
  LAMBDA_SG_ID="${LAMBDA_SECURITY_GROUP_IDS%%,*}"
fi
IFS=',' read -r -a LAMBDA_SECURITY_GROUP_ID_ARRAY <<< "$LAMBDA_SECURITY_GROUP_IDS"

echo "Authorizing Lambda to reach Redis on 6379"
aws ec2 authorize-security-group-ingress \
  --group-id "$REDIS_SG_ID" \
  --protocol tcp \
  --port 6379 \
  --source-group "$LAMBDA_SG_ID" \
  --region "$AWS_REGION" >/dev/null 2>&1 || true

echo "Creating or locating ElastiCache Serverless cache: $REDIS_CACHE_NAME"
if ! aws elasticache describe-serverless-caches \
  --serverless-cache-name "$REDIS_CACHE_NAME" \
  --region "$AWS_REGION" >/dev/null 2>&1; then
  aws elasticache create-serverless-cache \
    --serverless-cache-name "$REDIS_CACHE_NAME" \
    --engine "$REDIS_ENGINE" \
    --subnet-ids "${SUBNET_ID_ARRAY[@]}" \
    --security-group-ids "${REDIS_SECURITY_GROUP_ID_ARRAY[@]}" \
    --region "$AWS_REGION" >/dev/null
fi

echo "Waiting for ElastiCache endpoint"
REDIS_ENDPOINT=""
for _ in $(seq 1 60); do
  REDIS_ENDPOINT="$(aws elasticache describe-serverless-caches \
    --serverless-cache-name "$REDIS_CACHE_NAME" \
    --query 'ServerlessCaches[0].Endpoint.Address' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || true)"
  if [[ -n "$REDIS_ENDPOINT" && "$REDIS_ENDPOINT" != "None" ]]; then
    break
  fi
  sleep 10
done
if [[ -z "$REDIS_ENDPOINT" || "$REDIS_ENDPOINT" == "None" ]]; then
  echo "ElastiCache endpoint was not available in time." >&2
  exit 1
fi
REDIS_ADDR="$REDIS_ENDPOINT:6379"

cat > "$BUILD_DIR/trust-policy.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"Service": "lambda.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }
  ]
}
JSON

echo "Creating or updating IAM worker role"
if ! aws iam get-role --role-name "$WORKER_ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role \
    --role-name "$WORKER_ROLE_NAME" \
    --assume-role-policy-document "file://$BUILD_DIR/trust-policy.json" >/dev/null
fi

cat > "$BUILD_DIR/worker-policy.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:$AWS_REGION:$ACCOUNT_ID:*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
        "sqs:ChangeMessageVisibility"
      ],
      "Resource": "$QUEUE_ARN"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ec2:CreateNetworkInterface",
        "ec2:DescribeNetworkInterfaces",
        "ec2:DescribeSubnets",
        "ec2:DeleteNetworkInterface",
        "ec2:AssignPrivateIpAddresses",
        "ec2:UnassignPrivateIpAddresses"
      ],
      "Resource": "*"
    }
  ]
}
JSON

aws iam put-role-policy \
  --role-name "$WORKER_ROLE_NAME" \
  --policy-name "$PROJECT_NAME-$STAGE_NAME-worker-policy" \
  --policy-document "file://$BUILD_DIR/worker-policy.json" >/dev/null
ROLE_ARN="$(aws iam get-role --role-name "$WORKER_ROLE_NAME" --query Role.Arn --output text)"

echo "Waiting for IAM role propagation"
aws iam wait role-exists --role-name "$WORKER_ROLE_NAME"
sleep 10

echo "Building custom runtime Lambda binary"
rm -f "$BUILD_DIR/bootstrap" "$ZIP_PATH"
(
  cd "$ROOT_DIR"
  GOOS=linux GOARCH=arm64 CGO_ENABLED=0 GOCACHE="$ROOT_DIR/.gocache" go build -o "$BUILD_DIR/bootstrap" ./cmd/worker-lambda
)
(cd "$BUILD_DIR" && zip -q "$ZIP_PATH" bootstrap)

ENV_VARS="Variables={REDIS_ADDR=$REDIS_ADDR,REDIS_TLS=false,AGGREGATE_TTL_SECONDS=$AGGREGATE_TTL_SECONDS}"
VPC_CONFIG="SubnetIds=[$SUBNET_IDS],SecurityGroupIds=[$LAMBDA_SECURITY_GROUP_IDS]"

echo "Creating or updating worker Lambda: $WORKER_FUNCTION_NAME"
if aws lambda get-function --function-name "$WORKER_FUNCTION_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  aws lambda update-function-code \
    --function-name "$WORKER_FUNCTION_NAME" \
    --zip-file "fileb://$ZIP_PATH" \
    --architectures arm64 \
    --region "$AWS_REGION" >/dev/null
  aws lambda wait function-updated --function-name "$WORKER_FUNCTION_NAME" --region "$AWS_REGION"
  aws lambda update-function-configuration \
    --function-name "$WORKER_FUNCTION_NAME" \
    --runtime provided.al2023 \
    --handler bootstrap \
    --timeout 120 \
    --memory-size 1024 \
    --environment "$ENV_VARS" \
    --vpc-config "$VPC_CONFIG" \
    --region "$AWS_REGION" >/dev/null
else
  aws lambda create-function \
    --function-name "$WORKER_FUNCTION_NAME" \
    --runtime provided.al2023 \
    --role "$ROLE_ARN" \
    --handler bootstrap \
    --zip-file "fileb://$ZIP_PATH" \
    --architectures arm64 \
    --timeout 120 \
    --memory-size 1024 \
    --environment "$ENV_VARS" \
    --vpc-config "$VPC_CONFIG" \
    --region "$AWS_REGION" >/dev/null
fi

if [[ -n "$WORKER_RESERVED_CONCURRENCY" ]]; then
  echo "Setting worker reserved concurrency to $WORKER_RESERVED_CONCURRENCY"
  if ! aws lambda put-function-concurrency \
    --function-name "$WORKER_FUNCTION_NAME" \
    --reserved-concurrent-executions "$WORKER_RESERVED_CONCURRENCY" \
    --region "$AWS_REGION" >/dev/null; then
    echo "Warning: unable to reserve $WORKER_RESERVED_CONCURRENCY Lambda executions. Continuing without reserved concurrency." >&2
    echo "Request a Lambda concurrency quota increase if you need a guaranteed 100-worker reservation." >&2
  fi
else
  echo "Skipping reserved concurrency. SQS event source max concurrency remains $WORKER_MAX_CONCURRENCY."
fi

echo "Creating SQS event source mapping"
MAPPING_UUID="$(aws lambda list-event-source-mappings \
  --function-name "$WORKER_FUNCTION_NAME" \
  --event-source-arn "$QUEUE_ARN" \
  --query 'EventSourceMappings[0].UUID' \
  --output text \
  --region "$AWS_REGION")"
if [[ "$MAPPING_UUID" == "None" || -z "$MAPPING_UUID" ]]; then
  aws lambda create-event-source-mapping \
    --function-name "$WORKER_FUNCTION_NAME" \
    --event-source-arn "$QUEUE_ARN" \
    --batch-size "$WORKER_BATCH_SIZE" \
    --function-response-types ReportBatchItemFailures \
    --scaling-config "MaximumConcurrency=$WORKER_MAX_CONCURRENCY" \
    --region "$AWS_REGION" >/dev/null
else
  aws lambda update-event-source-mapping \
    --uuid "$MAPPING_UUID" \
    --batch-size "$WORKER_BATCH_SIZE" \
    --function-response-types ReportBatchItemFailures \
    --scaling-config "MaximumConcurrency=$WORKER_MAX_CONCURRENCY" \
    --region "$AWS_REGION" >/dev/null
fi

cat > "$BUILD_DIR/outputs.json" <<JSON
{
  "queue_url": "$QUEUE_URL",
  "queue_arn": "$QUEUE_ARN",
  "dlq_url": "$DLQ_URL",
  "redis_cache_name": "$REDIS_CACHE_NAME",
  "redis_addr": "$REDIS_ADDR",
  "worker_function_name": "$WORKER_FUNCTION_NAME",
  "worker_max_concurrency": "$WORKER_MAX_CONCURRENCY",
  "worker_reserved_concurrency": "${WORKER_RESERVED_CONCURRENCY:-null}"
}
JSON

cat "$BUILD_DIR/outputs.json"
