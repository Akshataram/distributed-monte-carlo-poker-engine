# Distributed Monte Carlo Poker Analysis Engine

## Target AWS Flow

1. API Gateway receives a hand-analysis request.
2. Ingestion Lambda validates cards, resolves or creates a `HandID`, stores session metadata, and emits worker chunks to SQS.
3. SQS buffers work and decouples request traffic from compute throughput.
4. Lambda workers consume chunks, run local Monte Carlo simulations, and emit partial counters.
5. ElastiCache Redis or Valkey performs atomic fan-in with `INCRBY`/`HINCRBY`.
6. Aggregator Lambda checks the completion barrier and returns equity once all chunks finish.

## Idempotency Model

Each simulation chunk is identified by:

```text
hand_id + board_version + chunk_id
```

The chunk seed is derived deterministically from:

```text
hand_id + board_version + chunk_id + base_seed
```

This lets a retried worker recompute the same local simulation for the same chunk identity. In production, the result is applied only once through the idempotency claim below.

Workers must claim a chunk result before applying counters:

```text
SETNX processed:{hand_id}:{board_version}:{chunk_id} 1
HINCRBY aggregate:{hand_id}:{board_version} wins <n>
HINCRBY aggregate:{hand_id}:{board_version} ties <n>
HINCRBY aggregate:{hand_id}:{board_version} losses <n>
HINCRBY aggregate:{hand_id}:{board_version} equity_micros <n>
HINCRBY aggregate:{hand_id}:{board_version} completed_chunks 1
```

If `SETNX` fails, the worker exits successfully because another invocation already applied the result.

## Local-First Boundary

The `internal/poker` package has no AWS dependencies. Lambda handlers should live in separate adapter packages and call the same pure simulation API used by the local CLI.
