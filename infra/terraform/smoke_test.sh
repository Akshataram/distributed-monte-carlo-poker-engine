#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

API_URL="$(terraform -chdir="$SCRIPT_DIR" output -raw hands_url 2>/dev/null || true)"
API_ENDPOINT="$(terraform -chdir="$SCRIPT_DIR" output -raw api_endpoint 2>/dev/null || true)"

if [ -z "$API_URL" ] || [ -z "$API_ENDPOINT" ]; then
  echo "Terraform outputs are missing. Run './infra/terraform/deploy.sh apply' successfully before smoke_test.sh." >&2
  exit 1
fi

echo "Submitting real AWS simulation through API Gateway"
CREATE_RESPONSE="$(curl -sS -X POST "$API_URL" \
  -H 'content-type: application/json' \
  -d '{
    "hero":["As","Ah"],
    "board":[],
    "opponents":1,
    "total_iterations":100000,
    "iterations_per_chunk":10000
  }')"

echo "$CREATE_RESPONSE"

if python3 -c 'import json,sys; body=json.load(sys.stdin); sys.exit(0 if "hand_id" in body else 1)' <<< "$CREATE_RESPONSE"; then
  HAND_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["hand_id"])' <<< "$CREATE_RESPONSE")"
else
  echo "Ingestion did not return a hand_id. Response above is the failure to debug." >&2
  exit 1
fi

BOARD_VERSION="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("board_version", 0))' <<< "$CREATE_RESPONSE")"
RESULT_URL="${API_ENDPOINT}/hands/${HAND_ID}/results?board_version=${BOARD_VERSION}"

echo "Polling: $RESULT_URL"

for _ in $(seq 1 30); do
  RESULT="$(curl -sS "$RESULT_URL")"
  echo "$RESULT"
  STATUS="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("status", ""))' <<< "$RESULT")"
  if [ "$STATUS" = "complete" ]; then
    exit 0
  fi
  sleep 2
done

echo "Simulation did not complete within smoke-test timeout." >&2
exit 1
