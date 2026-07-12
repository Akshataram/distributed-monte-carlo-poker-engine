# AWS CLI Deployment

This folder contains direct AWS CLI automation for Phase 4.

## Deploy Worker + Redis Aggregation

Phase 3 provisions the real worker side:

```bash
cd /path/to/poker-engine
source infra/aws-cli/env.example
export VPC_ID=vpc-...
export SUBNET_IDS=subnet-a,subnet-b
./infra/aws-cli/deploy_phase3_worker.sh
```

The script creates or updates:

- SQS worker queue and DLQ
- ElastiCache Serverless Redis/Valkey cache
- Lambda worker IAM role
- Go custom-runtime worker Lambda
- SQS event source mapping with `ReportBatchItemFailures`
- SQS event source maximum concurrency set to `100`

The worker applies results through Redis Lua so duplicate SQS deliveries cannot double-count chunk output.

Reserved concurrency is optional. If your AWS account has enough Lambda concurrency quota, set:

```bash
export WORKER_RESERVED_CONCURRENCY=100
```

If not set, the deploy still caps the SQS event source mapping at `WORKER_MAX_CONCURRENCY`.

## Deploy Ingestion

```bash
cd /path/to/poker-engine
source infra/aws-cli/env.example
./infra/aws-cli/deploy_phase4_ingestion.sh
```

The script creates or updates:

- SQS worker queue
- DynamoDB hand-session table with TTL
- IAM role and inline policy for the ingestion Lambda
- Python ingestion Lambda
- HTTP API Gateway route: `POST /hands`

## Test Request

After deployment, use the `hands_url` from `.build/phase4/outputs.json`.

```bash
curl -sS "$HANDS_URL" \
  -H 'content-type: application/json' \
  -d '{
    "hero": ["As", "Ah"],
    "board": [],
    "opponents": 1,
    "total_iterations": 1000000,
    "iterations_per_chunk": 10000,
    "base_seed": 42
  }'
```

## Deploy Result Status API

Phase 5 adds:

```text
GET /hands/{hand_id}/results?board_version=0
```

Deploy:

```bash
export VPC_ID=vpc-...
export SUBNET_IDS=subnet-a,subnet-b
export LAMBDA_SECURITY_GROUP_IDS=sg-...
./infra/aws-cli/deploy_phase5_status.sh
```

Then query:

```bash
curl -sS "$API_ENDPOINT/hands/$HAND_ID/results?board_version=0"
```

For continuation after the flop, pass the returned `hand_id`:

```bash
curl -sS "$HANDS_URL" \
  -H 'content-type: application/json' \
  -d '{
    "hand_id": "<returned-hand-id>",
    "board": ["Ks", "Qs", "Js"]
  }'
```
