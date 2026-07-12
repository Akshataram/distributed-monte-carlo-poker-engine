import hashlib
import json
import os
import struct
import time
import uuid

import boto3


TABLE_NAME = os.environ["HAND_SESSIONS_TABLE"]
QUEUE_URL = os.environ["WORK_QUEUE_URL"]
DEFAULT_TOTAL_ITERATIONS = int(os.environ.get("DEFAULT_TOTAL_ITERATIONS", "1000000"))
DEFAULT_ITERATIONS_PER_CHUNK = int(os.environ.get("DEFAULT_ITERATIONS_PER_CHUNK", "10000"))
SESSION_TTL_SECONDS = int(os.environ.get("SESSION_TTL_SECONDS", "86400"))

dynamodb = boto3.resource("dynamodb")
sqs = boto3.client("sqs")
sessions = dynamodb.Table(TABLE_NAME)

RANKS = "23456789TJQKA"
SUITS = "cdhs"


def handler(event, context):
    try:
        body = parse_body(event)
        response = ingest(body)
        return api_response(202, response)
    except ValidationError as exc:
        return api_response(400, {"error": str(exc)})
    except Exception as exc:
        print(json.dumps({"level": "error", "message": str(exc)}))
        return api_response(500, {"error": "internal server error"})


def ingest(body):
    now = int(time.time())
    hand_id = body.get("hand_id") or str(uuid.uuid4())
    existing = get_session(hand_id)

    hero = resolve_hero(body, existing)
    board = resolve_board(body, existing)
    opponents = int(body.get("opponents", existing.get("opponents", 1) if existing else 1))
    total_iterations = int(
        body.get("total_iterations", existing.get("total_iterations", DEFAULT_TOTAL_ITERATIONS) if existing else DEFAULT_TOTAL_ITERATIONS)
    )
    iterations_per_chunk = int(
        body.get(
            "iterations_per_chunk",
            existing.get("iterations_per_chunk", DEFAULT_ITERATIONS_PER_CHUNK) if existing else DEFAULT_ITERATIONS_PER_CHUNK,
        )
    )
    base_seed = int(body.get("base_seed", existing.get("base_seed", 42) if existing else 42))

    validate_cards(hero, board)
    if opponents <= 0:
        raise ValidationError("opponents must be positive")
    if total_iterations <= 0:
        raise ValidationError("total_iterations must be positive")
    if iterations_per_chunk <= 0:
        raise ValidationError("iterations_per_chunk must be positive")
    if base_seed == 0:
        raise ValidationError("base_seed must be non-zero")

    board_version = len(board)
    chunks = build_chunk_messages(
        hand_id=hand_id,
        board_version=board_version,
        hero=hero,
        board=board,
        opponents=opponents,
        total_iterations=total_iterations,
        iterations_per_chunk=iterations_per_chunk,
        base_seed=base_seed,
    )

    put_session(
        hand_id=hand_id,
        hero=hero,
        board=board,
        board_version=board_version,
        opponents=opponents,
        total_iterations=total_iterations,
        iterations_per_chunk=iterations_per_chunk,
        base_seed=base_seed,
        expected_chunks=len(chunks),
        now=now,
        existed=existing is not None,
    )
    enqueue_chunks(chunks)

    return {
        "hand_id": hand_id,
        "board_version": board_version,
        "expected_chunks": len(chunks),
        "enqueued_chunks": len(chunks),
        "iterations_per_chunk": iterations_per_chunk,
        "total_iterations": total_iterations,
        "status": "queued",
    }


def parse_body(event):
    raw = event.get("body") or "{}"
    if event.get("isBase64Encoded"):
        raise ValidationError("base64 request bodies are not supported")
    try:
        body = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ValidationError(f"invalid JSON body: {exc}") from exc
    if not isinstance(body, dict):
        raise ValidationError("request body must be a JSON object")
    return body


def get_session(hand_id):
    result = sessions.get_item(Key={"hand_id": hand_id})
    return result.get("Item")


def resolve_hero(body, existing):
    if "hero" in body:
        hero = body["hero"]
        if existing and existing.get("hero") and list(existing["hero"]) != hero:
            raise ValidationError("hero cannot change for an existing hand_id")
        return hero
    if existing and existing.get("hero"):
        return list(existing["hero"])
    raise ValidationError("hero is required for a new hand session")


def resolve_board(body, existing):
    incoming = body.get("board")
    previous = list(existing.get("board", [])) if existing else []
    if incoming is None:
        return previous
    if len(incoming) < len(previous):
        raise ValidationError("board cannot move backwards for an existing hand_id")
    if previous and incoming[: len(previous)] != previous:
        raise ValidationError("new board must preserve previously known community cards")
    return incoming


def validate_cards(hero, board):
    if not isinstance(hero, list) or len(hero) != 2:
        raise ValidationError("hero must contain exactly two cards")
    if not isinstance(board, list) or len(board) > 5:
        raise ValidationError("board must contain zero to five cards")

    seen = set()
    for card in hero + board:
        if not isinstance(card, str) or len(card) != 2:
            raise ValidationError(f"invalid card {card!r}")
        normalized = card[0].upper() + card[1].lower()
        if normalized[0] not in RANKS or normalized[1] not in SUITS:
            raise ValidationError(f"invalid card {card!r}")
        if normalized in seen:
            raise ValidationError(f"duplicate card {normalized}")
        seen.add(normalized)


def build_chunk_messages(hand_id, board_version, hero, board, opponents, total_iterations, iterations_per_chunk, base_seed):
    chunk_count = (total_iterations + iterations_per_chunk - 1) // iterations_per_chunk
    messages = []
    remaining = total_iterations
    for chunk_id in range(chunk_count):
        iterations = min(iterations_per_chunk, remaining)
        messages.append(
            {
                "hand_id": hand_id,
                "board_version": board_version,
                "chunk_id": chunk_id,
                "expected_chunks": chunk_count,
                "hero": hero,
                "board": board,
                "opponents": opponents,
                "iterations": iterations,
                "seed": derive_chunk_seed(hand_id, board_version, chunk_id, base_seed),
            }
        )
        remaining -= iterations
    return messages


def derive_chunk_seed(hand_id, board_version, chunk_id, base_seed):
    h = hashlib.blake2b(digest_size=8)
    h.update(hand_id.encode("utf-8"))
    h.update(struct.pack("<q", board_version))
    h.update(struct.pack("<q", chunk_id))
    h.update(struct.pack("<q", base_seed))
    seed = int.from_bytes(h.digest(), "little") & 0x7FFFFFFFFFFFFFFF
    return seed or 1


def put_session(
    hand_id,
    hero,
    board,
    board_version,
    opponents,
    total_iterations,
    iterations_per_chunk,
    base_seed,
    expected_chunks,
    now,
    existed,
):
    item = {
        "hand_id": hand_id,
        "hero": hero,
        "board": board,
        "board_version": board_version,
        "opponents": opponents,
        "total_iterations": total_iterations,
        "iterations_per_chunk": iterations_per_chunk,
        "base_seed": base_seed,
        "expected_chunks": expected_chunks,
        "status": "queued",
        "updated_at": now,
        "expires_at": now + SESSION_TTL_SECONDS,
    }
    if not existed:
        item["created_at"] = now
    sessions.put_item(Item=item)


def enqueue_chunks(chunks):
    for start in range(0, len(chunks), 10):
        batch = chunks[start : start + 10]
        entries = [{"Id": str(chunk["chunk_id"]), "MessageBody": json.dumps(chunk, separators=(",", ":"))} for chunk in batch]
        result = sqs.send_message_batch(QueueUrl=QUEUE_URL, Entries=entries)
        failures = result.get("Failed", [])
        if failures:
            raise RuntimeError(f"failed to enqueue {len(failures)} chunks: {failures}")


def api_response(status_code, payload):
    return {
        "statusCode": status_code,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(payload, separators=(",", ":")),
    }


class ValidationError(Exception):
    pass
