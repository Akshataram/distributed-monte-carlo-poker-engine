# Distributed Monte Carlo Poker Analysis Engine

Local-first core for a future AWS fan-out/fan-in poker equity engine.

## Layout

```text
cmd/sim/              Local Monte Carlo CLI. No AWS dependencies.
internal/poker/       Pure card parsing, bit-mask evaluator, and simulator.
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
```
