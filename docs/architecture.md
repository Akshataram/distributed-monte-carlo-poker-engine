# Distributed Monte Carlo Poker Analysis Engine

## Target AWS Flow

1. API Gateway receives a hand-analysis request.
2. Ingestion Lambda validates cards, resolves or creates a `HandID`, stores session metadata, and emits worker chunks to SQS.
3. SQS buffers work and decouples request traffic from compute throughput.
4. Lambda workers consume chunks, run local Monte Carlo simulations, and emit partial counters.
5. ElastiCache Redis or Valkey performs atomic fan-in with `INCRBY`/`HINCRBY`.
6. Aggregator Lambda checks the completion barrier and returns equity once all chunks finish.

## Worker Message Contract

The SQS message body is intentionally small and deterministic:

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

This is enough for a worker to recompute the same chunk on retry without reading shared mutable simulation state.

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

## Phase 3 Worker Boundary

The current implementation adds `internal/worker`, which has three responsibilities:

1. Decode and validate an SQS-shaped chunk message.
2. Run `poker.SimulateChunk` for that exact chunk.
3. Apply counters through an `Aggregator` interface.

The production Redis adapter should implement the same interface with an atomic operation equivalent to:

```text
SETNX processed:{hand_id}:{board_version}:{chunk_id} 1
HINCRBY aggregate:{hand_id}:{board_version} iterations <n>
HINCRBY aggregate:{hand_id}:{board_version} wins <n>
HINCRBY aggregate:{hand_id}:{board_version} ties <n>
HINCRBY aggregate:{hand_id}:{board_version} losses <n>
HINCRBY aggregate:{hand_id}:{board_version} equity_micros <n>
HINCRBY aggregate:{hand_id}:{board_version} completed_chunks 1
```

In Redis, these commands should be wrapped in a Lua script or transaction-like flow so the idempotency claim and counter updates are applied as one unit.

## Local-First Boundary

The `internal/poker` package has no AWS dependencies. Lambda handlers should live in separate adapter packages and call the same pure simulation API used by the local CLI.
