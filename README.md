# Distributed Monte Carlo Poker Analysis Engine

Local-first core for a future AWS fan-out/fan-in poker equity engine.

## Layout

```text
cmd/sim/              Local Monte Carlo CLI. No AWS dependencies.
internal/poker/       Pure card parsing, bit-mask evaluator, chunking, and simulator.
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
```

## Phase 2: Deterministic worker chunks

The local CLI can now split one analysis into deterministic worker-sized chunks before any AWS services are introduced.

Each chunk has:

```text
hand_id + board_version + chunk_id + iterations + seed
```

That tuple becomes the future SQS message body and Redis idempotency key. Partial results are mergeable with integer `EquityMicros`, which maps directly to Redis `INCRBY` and avoids distributed floating-point aggregation drift.
