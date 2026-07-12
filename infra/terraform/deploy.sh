#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ACTION="${1:-plan}"

echo "Checking prerequisites..."

# 1. Check if Go is installed
if ! command -v go >/dev/null 2>&1; then
  echo "Error: 'go' command is not available. Please install Go to build the lambda custom runtime binaries." >&2
  exit 1
fi

# 2. Check if Terraform is installed
if ! command -v terraform >/dev/null 2>&1; then
  echo "Warning: 'terraform' command not found in PATH." >&2
  echo "You will need to install Terraform (e.g. 'brew install terraform') to execute the plan." >&2
  echo "Alternatively, you can run the AWS CLI deployment in 'infra/aws-cli/' which does not require Terraform." >&2
  exit 1
fi

# 3. Check for terraform.tfvars
if [ ! -f "$SCRIPT_DIR/terraform.tfvars" ]; then
  echo "=========================================================================" >&2
  echo "Configuration Required:" >&2
  echo "Please copy '$SCRIPT_DIR/terraform.tfvars.example' to '$SCRIPT_DIR/terraform.tfvars'" >&2
  echo "and update 'vpc_id' and 'subnet_ids' before deploying." >&2
  echo "=========================================================================" >&2
  exit 1
fi

echo "Prerequisites checked. Initializing Terraform..."
cd "$SCRIPT_DIR"

terraform init -upgrade
terraform validate

case "$ACTION" in
  plan)
    echo "Running Terraform plan..."
    terraform plan
    ;;
  apply)
    echo "Running Terraform apply..."
    terraform apply
    ;;
  *)
    echo "Usage: $0 [plan|apply]" >&2
    exit 1
    ;;
esac
