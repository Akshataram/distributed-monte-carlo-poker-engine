#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/phase4"
mkdir -p "$BUILD_DIR"

AWS_REGION="${AWS_REGION:-us-east-1}"
PROJECT_NAME="${PROJECT_NAME:-poker-ev}"
STAGE_NAME="${STAGE_NAME:-dev}"
LAMBDA_RUNTIME="${LAMBDA_RUNTIME:-python3.12}"
DEFAULT_TOTAL_ITERATIONS="${DEFAULT_TOTAL_ITERATIONS:-1000000}"
DEFAULT_ITERATIONS_PER_CHUNK="${DEFAULT_ITERATIONS_PER_CHUNK:-10000}"
SESSION_TTL_SECONDS="${SESSION_TTL_SECONDS:-86400}"

QUEUE_NAME="$PROJECT_NAME-$STAGE_NAME-work"
TABLE_NAME="$PROJECT_NAME-$STAGE_NAME-hand-sessions"
ROLE_NAME="$PROJECT_NAME-$STAGE_NAME-ingestion-role"
FUNCTION_NAME="$PROJECT_NAME-$STAGE_NAME-ingestion"
API_NAME="$PROJECT_NAME-$STAGE_NAME-http"
ZIP_PATH="$BUILD_DIR/ingestion.zip"

echo "Deploying Phase 4 ingestion stack to region $AWS_REGION"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text --region "$AWS_REGION")"

echo "Creating or locating SQS queue: $QUEUE_NAME"
QUEUE_URL="$(aws sqs create-queue \
  --queue-name "$QUEUE_NAME" \
  --attributes VisibilityTimeout=120,MessageRetentionPeriod=86400 \
  --query QueueUrl \
  --output text \
  --region "$AWS_REGION")"
QUEUE_ARN="$(aws sqs get-queue-attributes \
  --queue-url "$QUEUE_URL" \
  --attribute-names QueueArn \
  --query 'Attributes.QueueArn' \
  --output text \
  --region "$AWS_REGION")"

echo "Creating DynamoDB table if needed: $TABLE_NAME"
if ! aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  aws dynamodb create-table \
    --table-name "$TABLE_NAME" \
    --attribute-definitions AttributeName=hand_id,AttributeType=S \
    --key-schema AttributeName=hand_id,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$AWS_REGION" >/dev/null
  aws dynamodb wait table-exists --table-name "$TABLE_NAME" --region "$AWS_REGION"
  aws dynamodb update-time-to-live \
    --table-name "$TABLE_NAME" \
    --time-to-live-specification Enabled=true,AttributeName=expires_at \
    --region "$AWS_REGION" >/dev/null
fi

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

cat > "$BUILD_DIR/ingestion-policy.json" <<JSON
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
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:UpdateItem"
      ],
      "Resource": "arn:aws:dynamodb:$AWS_REGION:$ACCOUNT_ID:table/$TABLE_NAME"
    },
    {
      "Effect": "Allow",
      "Action": [
        "sqs:SendMessage",
        "sqs:SendMessageBatch"
      ],
      "Resource": "$QUEUE_ARN"
    }
  ]
}
JSON

aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "$PROJECT_NAME-$STAGE_NAME-ingestion-policy" \
  --policy-document "file://$BUILD_DIR/ingestion-policy.json" >/dev/null
ROLE_ARN="$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text)"

echo "Packaging Lambda: $ZIP_PATH"
rm -f "$ZIP_PATH"
(cd "$ROOT_DIR/cmd/ingestion-lambda" && zip -qr "$ZIP_PATH" app.py)

ENV_VARS="Variables={HAND_SESSIONS_TABLE=$TABLE_NAME,WORK_QUEUE_URL=$QUEUE_URL,DEFAULT_TOTAL_ITERATIONS=$DEFAULT_TOTAL_ITERATIONS,DEFAULT_ITERATIONS_PER_CHUNK=$DEFAULT_ITERATIONS_PER_CHUNK,SESSION_TTL_SECONDS=$SESSION_TTL_SECONDS}"

echo "Creating or updating Lambda: $FUNCTION_NAME"
if aws lambda get-function --function-name "$FUNCTION_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  aws lambda update-function-code \
    --function-name "$FUNCTION_NAME" \
    --zip-file "fileb://$ZIP_PATH" \
    --region "$AWS_REGION" >/dev/null
  aws lambda wait function-updated --function-name "$FUNCTION_NAME" --region "$AWS_REGION"
  aws lambda update-function-configuration \
    --function-name "$FUNCTION_NAME" \
    --runtime "$LAMBDA_RUNTIME" \
    --handler app.handler \
    --timeout 30 \
    --memory-size 512 \
    --environment "$ENV_VARS" \
    --region "$AWS_REGION" >/dev/null
else
  aws lambda create-function \
    --function-name "$FUNCTION_NAME" \
    --runtime "$LAMBDA_RUNTIME" \
    --role "$ROLE_ARN" \
    --handler app.handler \
    --zip-file "fileb://$ZIP_PATH" \
    --timeout 30 \
    --memory-size 512 \
    --environment "$ENV_VARS" \
    --region "$AWS_REGION" >/dev/null
fi
FUNCTION_ARN="$(aws lambda get-function --function-name "$FUNCTION_NAME" --query Configuration.FunctionArn --output text --region "$AWS_REGION")"

echo "Creating or locating HTTP API: $API_NAME"
API_ID="$(aws apigatewayv2 get-apis \
  --query "Items[?Name=='$API_NAME'].ApiId | [0]" \
  --output text \
  --region "$AWS_REGION")"
if [[ "$API_ID" == "None" || -z "$API_ID" ]]; then
  API_ID="$(aws apigatewayv2 create-api \
    --name "$API_NAME" \
    --protocol-type HTTP \
    --query ApiId \
    --output text \
    --region "$AWS_REGION")"
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

ROUTE_KEY="POST /hands"
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

aws apigatewayv2 create-stage \
  --api-id "$API_ID" \
  --stage-name '$default' \
  --auto-deploy \
  --region "$AWS_REGION" >/dev/null 2>&1 || true

aws lambda add-permission \
  --function-name "$FUNCTION_NAME" \
  --statement-id "$PROJECT_NAME-$STAGE_NAME-apigw-invoke" \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:$AWS_REGION:$ACCOUNT_ID:$API_ID/*/*/hands" \
  --region "$AWS_REGION" >/dev/null 2>&1 || true

API_ENDPOINT="$(aws apigatewayv2 get-api --api-id "$API_ID" --query ApiEndpoint --output text --region "$AWS_REGION")"

cat > "$BUILD_DIR/outputs.json" <<JSON
{
  "api_endpoint": "$API_ENDPOINT",
  "hands_url": "$API_ENDPOINT/hands",
  "queue_url": "$QUEUE_URL",
  "queue_arn": "$QUEUE_ARN",
  "table_name": "$TABLE_NAME",
  "function_name": "$FUNCTION_NAME",
  "api_id": "$API_ID"
}
JSON

cat "$BUILD_DIR/outputs.json"

