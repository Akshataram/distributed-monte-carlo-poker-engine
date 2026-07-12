#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGION="${AWS_REGION:-us-east-1}"
PROJECT_NAME="${PROJECT_NAME:-poker-ev}"
STAGE_NAME="${STAGE_NAME:-prod}"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text --region "$REGION")"
BUCKET="${TF_STATE_BUCKET:-${PROJECT_NAME}-terraform-state-${ACCOUNT_ID}-${REGION}}"
STATE_KEY="${TF_STATE_KEY:-${PROJECT_NAME}/${STAGE_NAME}/terraform.tfstate}"

echo "Bootstrapping Terraform remote state in AWS"
echo "Region: $REGION"
echo "Bucket: $BUCKET"
echo "State key: $STATE_KEY"

if ! aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  else
    aws s3api create-bucket \
      --bucket "$BUCKET" \
      --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
fi

aws s3api put-bucket-versioning \
  --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket "$BUCKET" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

cat > "$SCRIPT_DIR/backend.tf" <<BACKEND
terraform {
  backend "s3" {
    bucket       = "$BUCKET"
    key          = "$STATE_KEY"
    region       = "$REGION"
    encrypt      = true
    use_lockfile = true
  }
}
BACKEND

echo "Wrote $SCRIPT_DIR/backend.tf"
echo "Next: terraform -chdir=$SCRIPT_DIR init -migrate-state"
