# Distributed Monte Carlo Poker Analysis Engine

Local-first core for a future AWS fan-out/fan-in poker equity engine.

## Layout

```text
cmd/sim/              Local Monte Carlo CLI. No AWS dependencies.
cmd/ingestion-lambda/ AWS API Gateway ingestion Lambda.
cmd/worker-lambda/    AWS Lambda custom runtime worker for SQS.
cmd/worker-local/     Local worker harness for SQS-shaped chunk messages.
examples/             Example worker messages.
infra/aws-cli/        AWS CLI deployment scripts.
internal/poker/       Pure card parsing, bit-mask evaluator, chunking, and simulator.
internal/worker/      Worker processor and aggregation contract.
scripts/run_local.sh  Smoke test plus two reproducible local simulations.
```

Future AWS adapters should live outside `internal/poker`, for example:

```text
cmd/ingestion-lambda/
cmd/worker-lambda/
cmd/aggregator-lambda/
internal/awsadapter/
infra/terraform/
```

## Run locally

```bash
export GOCACHE="$PWD/.gocache"
go test ./...
go run ./cmd/sim -hero "As Ah" -opponents 1 -n 1000000 -seed 42
go run ./cmd/sim -hero "As Ks" -board "Qs Js 2d" -opponents 1 -n 1000000 -seed 42
go run ./cmd/sim -hero "As Ah" -opponents 1 -n 1000000 -chunk-size 10000 -hand-id demo-aa -seed 42
go run ./cmd/worker-local -message examples/chunk-message.json
```

## Phase 2: Deterministic worker chunks

The local CLI can now split one analysis into deterministic worker-sized chunks before any AWS services are introduced.

Each chunk has:

```text
hand_id + board_version + chunk_id + iterations + seed
```

That tuple becomes the future SQS message body and Redis idempotency key. Partial results are mergeable with integer `EquityMicros`, which maps directly to Redis `INCRBY` and avoids distributed floating-point aggregation drift.

## Phase 3: Worker processing boundary

The worker layer accepts an SQS-shaped JSON message:

```json
{
  "hand_id": "demo-aa",
  "board_version": 0,
  "chunk_id": 0,
  "expected_chunks": 10,
  "hero": ["As", "Ah"],
  "board": [],
  "opponents": 1,
  "iterations": 10000,
  "seed": 5988872962477750265
}
```

`internal/worker` validates the message, calls the pure poker simulator, and applies the partial result through an `Aggregator` interface. The included in-memory aggregator behaves like Redis idempotency: the first result for a chunk applies counters, and duplicate retries are acknowledged without double-counting.

Production Phase 3 adds `cmd/worker-lambda` and `internal/redisagg`. The worker is an AWS Lambda custom runtime subscribed to SQS. It applies results to ElastiCache Redis/Valkey through one Lua script so the idempotency claim and aggregate counter updates are atomic.

Deploy the worker side:

```bash
source infra/aws-cli/env.example
export VPC_ID=vpc-...
export SUBNET_IDS=subnet-a,subnet-b
./infra/aws-cli/deploy_phase3_worker.sh
```

`WORKER_MAX_CONCURRENCY=100` caps the SQS event source mapping. `WORKER_RESERVED_CONCURRENCY` is optional because smaller AWS accounts may not have enough Lambda quota to reserve 100 executions.

## Phase 4: AWS CLI ingestion layer

`infra/aws-cli/deploy_phase4_ingestion.sh` provisions the real ingestion path with AWS CLI:

```text
API Gateway HTTP API -> Ingestion Lambda -> DynamoDB session table + SQS worker queue
```

The ingestion Lambda implements hand-session continuity. A first request creates a `hand_id`; later requests can pass the same `hand_id` with additional community cards. The Lambda preserves hero cards and prior board cards, increments `board_version` from the number of known community cards, stores session state in DynamoDB, and emits deterministic SQS chunk messages.

Deploy:

```bash
source infra/aws-cli/env.example
./infra/aws-cli/deploy_phase4_ingestion.sh
```
