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

## Ingestion Session Continuity

The Phase 4 ingestion Lambda handles two request shapes.

New hand:

```json
{
  "hero": ["As", "Ah"],
  "board": [],
  "opponents": 1,
  "total_iterations": 1000000,
  "iterations_per_chunk": 10000,
  "base_seed": 42
}
```

Continuation:

```json
{
  "hand_id": "<existing-hand-id>",
  "board": ["Ks", "Qs", "Js"]
}
```

For continuation requests, hero cards and simulation settings are loaded from DynamoDB. The new board must preserve previous community cards and may only move forward. That prevents a stale client from accidentally changing the meaning of an existing `hand_id`.

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

The production worker now uses a Redis Lua script with this shape:

```text
SET processed:{hand_id}:{board_version}:{chunk_id} 1 NX EX ttl
if claim succeeds:
  HSET aggregate:{hand_id}:{board_version} expected_chunks n
  HINCRBY aggregate:{hand_id}:{board_version} completed_chunks 1
  HINCRBY aggregate:{hand_id}:{board_version} iterations n
  HINCRBY aggregate:{hand_id}:{board_version} wins n
  HINCRBY aggregate:{hand_id}:{board_version} ties n
  HINCRBY aggregate:{hand_id}:{board_version} losses n
  HINCRBY aggregate:{hand_id}:{board_version} equity_micros n
else:
  return existing aggregate snapshot
```

This is the required idempotency layer for SQS/Lambda at-least-once delivery.

The deploy script separates two concurrency concepts:

```text
WORKER_MAX_CONCURRENCY      caps SQS -> Lambda scaling
WORKER_RESERVED_CONCURRENCY optionally reserves Lambda account capacity
```

For interview defense: the target design uses 100-way worker concurrency, but small AWS accounts may need a Lambda quota increase before they can reserve 100 concurrent executions.

## Result Status API

The result API reads the Redis aggregate hash:

```text
aggregate:{hand_id}:{board_version}
```

It returns:

```text
status: running | complete
completed_chunks / expected_chunks
wins, ties, losses
equity and equity_percent
```

This keeps ingestion asynchronous. `POST /hands` queues work and returns quickly; `GET /hands/{hand_id}/results` polls the fan-in barrier.

ElastiCache Serverless endpoints are reached from VPC-attached Lambdas with TLS enabled.

## Local-First Boundary

The `internal/poker` package has no AWS dependencies. Lambda handlers should live in separate adapter packages and call the same pure simulation API used by the local CLI.
