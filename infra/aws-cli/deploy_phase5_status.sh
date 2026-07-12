#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/phase5"
mkdir -p "$BUILD_DIR"

AWS_REGION="${AWS_REGION:-us-east-1}"
PROJECT_NAME="${PROJECT_NAME:-poker-ev}"
STAGE_NAME="${STAGE_NAME:-dev}"
VPC_ID="${VPC_ID:-}"
SUBNET_IDS="${SUBNET_IDS:-}"
LAMBDA_SECURITY_GROUP_IDS="${LAMBDA_SECURITY_GROUP_IDS:-}"
REDIS_CACHE_NAME="${REDIS_CACHE_NAME:-$PROJECT_NAME-$STAGE_NAME-aggregate}"
API_NAME="$PROJECT_NAME-$STAGE_NAME-http"
ROLE_NAME="$PROJECT_NAME-$STAGE_NAME-status-role"
FUNCTION_NAME="$PROJECT_NAME-$STAGE_NAME-status"
ZIP_PATH="$BUILD_DIR/status.zip"

if [[ -z "$VPC_ID" ]]; then
  echo "VPC_ID is required because the status Lambda must reach Redis inside a VPC." >&2
  exit 1
fi
if [[ -z "$SUBNET_IDS" ]]; then
  echo "SUBNET_IDS is required as a comma-separated list, e.g. subnet-a,subnet-b." >&2
  exit 1
fi
if [[ -z "$LAMBDA_SECURITY_GROUP_IDS" ]]; then
  echo "LAMBDA_SECURITY_GROUP_IDS is required. Use the worker Lambda security group from Phase 3." >&2
  exit 1
fi

echo "Deploying Phase 5 status API to region $AWS_REGION"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text --region "$AWS_REGION")"

REDIS_ENDPOINT="$(aws elasticache describe-serverless-caches \
  --serverless-cache-name "$REDIS_CACHE_NAME" \
  --query 'ServerlessCaches[0].Endpoint.Address' \
  --output text \
  --region "$AWS_REGION")"
if [[ -z "$REDIS_ENDPOINT" || "$REDIS_ENDPOINT" == "None" ]]; then
  echo "Redis cache endpoint was not found for $REDIS_CACHE_NAME." >&2
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

echo "Creating or updating IAM role: $ROLE_NAME"
if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://$BUILD_DIR/trust-policy.json" >/dev/null
fi

cat > "$BUILD_DIR/status-policy.json" <<JSON
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
  --role-name "$ROLE_NAME" \
  --policy-name "$PROJECT_NAME-$STAGE_NAME-status-policy" \
  --policy-document "file://$BUILD_DIR/status-policy.json" >/dev/null
ROLE_ARN="$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text)"

echo "Waiting for IAM role propagation"
aws iam wait role-exists --role-name "$ROLE_NAME"
sleep 10

echo "Building status Lambda custom runtime"
rm -f "$BUILD_DIR/bootstrap" "$ZIP_PATH"
(
  cd "$ROOT_DIR"
  GOOS=linux GOARCH=arm64 CGO_ENABLED=0 GOCACHE="$ROOT_DIR/.gocache" go build -o "$BUILD_DIR/bootstrap" ./cmd/status-lambda
)
(cd "$BUILD_DIR" && zip -q "$ZIP_PATH" bootstrap)

ENV_VARS="Variables={REDIS_ADDR=$REDIS_ADDR,REDIS_TLS=false}"
VPC_CONFIG="SubnetIds=[$SUBNET_IDS],SecurityGroupIds=[$LAMBDA_SECURITY_GROUP_IDS]"

echo "Creating or updating status Lambda: $FUNCTION_NAME"
if aws lambda get-function --function-name "$FUNCTION_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  aws lambda wait function-active-v2 --function-name "$FUNCTION_NAME" --region "$AWS_REGION"
  aws lambda update-function-code \
    --function-name "$FUNCTION_NAME" \
    --zip-file "fileb://$ZIP_PATH" \
    --architectures arm64 \
    --region "$AWS_REGION" >/dev/null
  aws lambda wait function-updated --function-name "$FUNCTION_NAME" --region "$AWS_REGION"
  aws lambda update-function-configuration \
    --function-name "$FUNCTION_NAME" \
    --runtime provided.al2023 \
    --handler bootstrap \
    --timeout 10 \
    --memory-size 512 \
    --environment "$ENV_VARS" \
    --vpc-config "$VPC_CONFIG" \
    --region "$AWS_REGION" >/dev/null
  aws lambda wait function-updated --function-name "$FUNCTION_NAME" --region "$AWS_REGION"
else
  aws lambda create-function \
    --function-name "$FUNCTION_NAME" \
    --runtime provided.al2023 \
    --role "$ROLE_ARN" \
    --handler bootstrap \
    --zip-file "fileb://$ZIP_PATH" \
    --architectures arm64 \
    --timeout 10 \
    --memory-size 512 \
    --environment "$ENV_VARS" \
    --vpc-config "$VPC_CONFIG" \
    --region "$AWS_REGION" >/dev/null
  aws lambda wait function-active-v2 --function-name "$FUNCTION_NAME" --region "$AWS_REGION"
fi
FUNCTION_ARN="$(aws lambda get-function --function-name "$FUNCTION_NAME" --query Configuration.FunctionArn --output text --region "$AWS_REGION")"

echo "Locating HTTP API: $API_NAME"
API_ID="$(aws apigatewayv2 get-apis \
  --query "Items[?Name=='$API_NAME'].ApiId | [0]" \
  --output text \
  --region "$AWS_REGION")"
if [[ "$API_ID" == "None" || -z "$API_ID" ]]; then
  echo "API $API_NAME does not exist. Run ./infra/aws-cli/deploy_phase4_ingestion.sh first." >&2
  exit 1
fi

INTEGRATION_ID="$(aws apigatewayv2 get-integrations \
  --api-id "$API_ID" \
  --query "Items[?IntegrationUri=='$FUNCTION_ARN'].IntegrationId | [0]" \
  --output text \
  --region "$AWS_REGION")"
if [[ "$INTEGRATION_ID" == "None" || -z "$INTEGRATION_ID" ]]; then
  INTEGRATION_ID="$(aws apigatewayv2 create-integration \
    --api-id "$API_ID" \
    --integration-type AWS_PROXY \
    --integration-uri "$FUNCTION_ARN" \
    --payload-format-version "2.0" \
    --query IntegrationId \
    --output text \
    --region "$AWS_REGION")"
fi

ROUTE_KEY='GET /hands/{hand_id}/results'
ROUTE_ID="$(aws apigatewayv2 get-routes \
  --api-id "$API_ID" \
  --query "Items[?RouteKey=='$ROUTE_KEY'].RouteId | [0]" \
  --output text \
  --region "$AWS_REGION")"
if [[ "$ROUTE_ID" == "None" || -z "$ROUTE_ID" ]]; then
  aws apigatewayv2 create-route \
    --api-id "$API_ID" \
    --route-key "$ROUTE_KEY" \
    --target "integrations/$INTEGRATION_ID" \
    --region "$AWS_REGION" >/dev/null
fi

aws lambda add-permission \
  --function-name "$FUNCTION_NAME" \
  --statement-id "$PROJECT_NAME-$STAGE_NAME-status-apigw-invoke" \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:$AWS_REGION:$ACCOUNT_ID:$API_ID/*/*/hands/*/results" \
  --region "$AWS_REGION" >/dev/null 2>&1 || true

API_ENDPOINT="$(aws apigatewayv2 get-api --api-id "$API_ID" --query ApiEndpoint --output text --region "$AWS_REGION")"

cat > "$BUILD_DIR/outputs.json" <<JSON
{
  "api_endpoint": "$API_ENDPOINT",
  "result_url_template": "$API_ENDPOINT/hands/{hand_id}/results?board_version=0",
  "redis_addr": "$REDIS_ADDR",
  "function_name": "$FUNCTION_NAME",
  "api_id": "$API_ID"
}
JSON

cat "$BUILD_DIR/outputs.json"

