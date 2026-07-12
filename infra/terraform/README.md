# Terraform Deployment

This folder is the reproducible IaC version of the AWS stack:

- API Gateway HTTP API
- Ingestion Lambda
- SQS work queue and DLQ
- Worker Lambda with SQS fan-out
- ElastiCache Serverless Redis aggregation barrier
- Status Lambda
- DynamoDB hand-session table
- IAM roles and security groups
- CloudWatch log groups, API access logs, and basic operational alarms
- SQS server-side encryption and DynamoDB point-in-time recovery

It is intentionally separate from `infra/aws-cli/`. Your currently running AWS CLI stack is not changed unless you run `terraform apply`.

## Production AWS Execution

Use a fresh `stage_name` first, for example `tfdev`, so Terraform creates an isolated copy of the stack in AWS without touching the working `dev` deployment.

```bash
cd /Users/akshata/Documents/Codex/2026-07-12/act-as-a-principal-cloud-architect/work/poker-engine
cp infra/terraform/terraform.tfvars.example infra/terraform/terraform.tfvars
```

Edit `infra/terraform/terraform.tfvars`:

```hcl
aws_region   = "us-east-1"
project_name = "poker-ev"
stage_name   = "tfdev"

vpc_id = "vpc-035f70c943144c560"
subnet_ids = [
  "subnet-02a20b25e974cf805",
  "subnet-0703e528f76c4cc42"
]

redis_engine = "redis"
log_retention_days = 14
enable_cloudwatch_alarms = true
enable_dynamodb_point_in_time_recovery = true
worker_max_concurrency = 100
worker_reserved_concurrency = null
```

Then run:

```bash
terraform -chdir=infra/terraform fmt
terraform -chdir=infra/terraform init
terraform -chdir=infra/terraform validate
terraform -chdir=infra/terraform plan
terraform -chdir=infra/terraform apply
```

Or use the helper:

```bash
./infra/terraform/deploy.sh plan
./infra/terraform/deploy.sh apply
./infra/terraform/smoke_test.sh
```

After apply, test the real AWS API:

```bash
API_URL="$(terraform -chdir=infra/terraform output -raw hands_url)"

curl -sS -X POST "$API_URL" \
  -H 'content-type: application/json' \
  -d '{
    "hero_cards":["As","Ah"],
    "opponent_cards":["Kc","Kd"],
    "board_cards":[],
    "total_iterations":100000,
    "iterations_per_chunk":10000
  }'
```

Copy the returned `hand_id`, then query:

```bash
RESULT_URL="$(terraform -chdir=infra/terraform output -raw api_endpoint)/hands/HAND_ID/results?board_version=0"
curl -sS "$RESULT_URL"
```

## Remote State Bootstrap

For team-grade Terraform, create an S3 backend with native lockfile support before applying from multiple machines:

```bash
AWS_REGION=us-east-1 PROJECT_NAME=poker-ev STAGE_NAME=tfdev ./infra/terraform/bootstrap_backend.sh
terraform -chdir=infra/terraform init -migrate-state
```

The generated `backend.tf` is ignored by git because it is account/environment-specific. `backend.tf.example` documents the expected backend shape.

## Exact AWS Execution Commands

From your terminal:

```bash
cd /Users/akshata/Documents/Codex/2026-07-12/act-as-a-principal-cloud-architect/work/poker-engine

aws sts get-caller-identity --region us-east-1

cp infra/terraform/terraform.tfvars.example infra/terraform/terraform.tfvars
# edit terraform.tfvars and set:
# stage_name = "tfdev"
# vpc_id     = "vpc-035f70c943144c560"
# subnet_ids = ["subnet-02a20b25e974cf805", "subnet-0703e528f76c4cc42"]

AWS_REGION=us-east-1 PROJECT_NAME=poker-ev STAGE_NAME=tfdev ./infra/terraform/bootstrap_backend.sh
terraform -chdir=infra/terraform init -migrate-state
./infra/terraform/deploy.sh plan
./infra/terraform/deploy.sh apply
./infra/terraform/smoke_test.sh
```

## Adopting The Existing `dev` Stack

Do not point Terraform at `stage_name = "dev"` and apply immediately. Those resources already exist from the AWS CLI deployment, so Terraform needs imports first or it will try to create duplicate names.

Recommended interview-safe story:

1. AWS CLI scripts were used as the deployment bootstrap/debug path.
2. Terraform is now the reproducible IaC path.
3. Existing resources can be imported into Terraform state before Terraform takes ownership.

Example import shape:

```bash
terraform -chdir=infra/terraform import aws_sqs_queue.work https://sqs.us-east-1.amazonaws.com/637867483736/poker-ev-dev-work
terraform -chdir=infra/terraform import aws_sqs_queue.dlq https://sqs.us-east-1.amazonaws.com/637867483736/poker-ev-dev-work-dlq
terraform -chdir=infra/terraform import aws_dynamodb_table.sessions poker-ev-dev-hand-sessions
terraform -chdir=infra/terraform import aws_lambda_function.worker poker-ev-dev-worker
terraform -chdir=infra/terraform import aws_lambda_function.ingestion poker-ev-dev-ingestion
terraform -chdir=infra/terraform import aws_lambda_function.status poker-ev-dev-status
```

Only run imports when your `terraform.tfvars` exactly matches the existing `dev` names and networking.
