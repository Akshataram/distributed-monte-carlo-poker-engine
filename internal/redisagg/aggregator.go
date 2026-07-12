package redisagg

import (
	"context"
	"crypto/tls"
	"fmt"
	"net"
	"strconv"
	"time"

	"poker-engine/internal/worker"
)

const applyChunkScript = `
local processed = KEYS[1]
local aggregate = KEYS[2]
local ttl = tonumber(ARGV[1])
local iterations = tonumber(ARGV[2])
local wins = tonumber(ARGV[3])
local ties = tonumber(ARGV[4])
local losses = tonumber(ARGV[5])
local equity_micros = tonumber(ARGV[6])
local expected_chunks = tonumber(ARGV[7])

local claimed = redis.call("SET", processed, "1", "NX", "EX", ttl)
if not claimed then
  return {
    0,
    tonumber(redis.call("HGET", aggregate, "expected_chunks") or "0"),
    tonumber(redis.call("HGET", aggregate, "completed_chunks") or "0"),
    tonumber(redis.call("HGET", aggregate, "iterations") or "0"),
    tonumber(redis.call("HGET", aggregate, "wins") or "0"),
    tonumber(redis.call("HGET", aggregate, "ties") or "0"),
    tonumber(redis.call("HGET", aggregate, "losses") or "0"),
    tonumber(redis.call("HGET", aggregate, "equity_micros") or "0")
  }
end

redis.call("HSET", aggregate, "expected_chunks", expected_chunks)
local completed_chunks = redis.call("HINCRBY", aggregate, "completed_chunks", 1)
local total_iterations = redis.call("HINCRBY", aggregate, "iterations", iterations)
local total_wins = redis.call("HINCRBY", aggregate, "wins", wins)
local total_ties = redis.call("HINCRBY", aggregate, "ties", ties)
local total_losses = redis.call("HINCRBY", aggregate, "losses", losses)
local total_equity_micros = redis.call("HINCRBY", aggregate, "equity_micros", equity_micros)
redis.call("EXPIRE", aggregate, ttl)

return {
  1,
  expected_chunks,
  completed_chunks,
  total_iterations,
  total_wins,
  total_ties,
  total_losses,
  total_equity_micros
}
`

type Config struct {
	Addr     string
	Username string
	Password string
	UseTLS   bool
	TTL      time.Duration
	Timeout  time.Duration
}

type Aggregator struct {
	client *Client
	ttl    time.Duration
}

func New(config Config) (*Aggregator, error) {
	if config.Addr == "" {
		return nil, fmt.Errorf("redis address is required")
	}
	if config.TTL <= 0 {
		config.TTL = 24 * time.Hour
	}
	if config.Timeout <= 0 {
		config.Timeout = 2 * time.Second
	}
	client := &Client{
		addr:     config.Addr,
		username: config.Username,
		password: config.Password,
		useTLS:   config.UseTLS,
		timeout:  config.Timeout,
	}
	return &Aggregator{client: client, ttl: config.TTL}, nil
}

func (a *Aggregator) ApplyChunkResult(ctx context.Context, delta worker.AggregateDelta) (bool, worker.AggregateSnapshot, error) {
	if delta.ExpectedChunks <= 0 {
		return false, worker.AggregateSnapshot{}, fmt.Errorf("expected chunks must be positive")
	}

	processedKey := fmt.Sprintf("processed:%s:%d:%d", delta.HandID, delta.BoardVersion, delta.ChunkID)
	aggregateKey := fmt.Sprintf("aggregate:%s:%d", delta.HandID, delta.BoardVersion)
	reply, err := a.client.Do(ctx,
		"EVAL", applyChunkScript, "2", processedKey, aggregateKey,
		strconv.Itoa(int(a.ttl.Seconds())),
		strconv.Itoa(delta.Iterations),
		strconv.Itoa(delta.Wins),
		strconv.Itoa(delta.Ties),
		strconv.Itoa(delta.Losses),
		strconv.FormatInt(delta.EquityMicros, 10),
		strconv.Itoa(delta.ExpectedChunks),
	)
	if err != nil {
		return false, worker.AggregateSnapshot{}, err
	}

	values, ok := reply.([]any)
	if !ok || len(values) != 8 {
		return false, worker.AggregateSnapshot{}, fmt.Errorf("unexpected redis script reply: %#v", reply)
	}

	applied := asInt64(values[0]) == 1
	snapshot := worker.AggregateSnapshot{
		HandID:          delta.HandID,
		BoardVersion:    delta.BoardVersion,
		ExpectedChunks:  int(asInt64(values[1])),
		CompletedChunks: int(asInt64(values[2])),
		Iterations:      int(asInt64(values[3])),
		Wins:            int(asInt64(values[4])),
		Ties:            int(asInt64(values[5])),
		Losses:          int(asInt64(values[6])),
		EquityMicros:    asInt64(values[7]),
	}
	if snapshot.Iterations > 0 {
		snapshot.Equity = float64(snapshot.EquityMicros) / float64(snapshot.Iterations*1_000_000)
	}
	return applied, snapshot, nil
}

func (a *Aggregator) GetSnapshot(ctx context.Context, handID string, boardVersion int) (worker.AggregateSnapshot, bool, error) {
	if handID == "" {
		return worker.AggregateSnapshot{}, false, fmt.Errorf("hand id is required")
	}
	if boardVersion < 0 {
		return worker.AggregateSnapshot{}, false, fmt.Errorf("board version cannot be negative")
	}

	aggregateKey := fmt.Sprintf("aggregate:%s:%d", handID, boardVersion)
	reply, err := a.client.Do(ctx, "HGETALL", aggregateKey)
	if err != nil {
		return worker.AggregateSnapshot{}, false, err
	}
	values, ok := reply.([]any)
	if !ok {
		return worker.AggregateSnapshot{}, false, fmt.Errorf("unexpected redis HGETALL reply: %#v", reply)
	}
	if len(values) == 0 {
		return worker.AggregateSnapshot{}, false, nil
	}

	fields := map[string]int64{}
	for i := 0; i+1 < len(values); i += 2 {
		name, ok := values[i].(string)
		if !ok {
			continue
		}
		fields[name] = asInt64(values[i+1])
	}

	snapshot := worker.AggregateSnapshot{
		HandID:          handID,
		BoardVersion:    boardVersion,
		ExpectedChunks:  int(fields["expected_chunks"]),
		CompletedChunks: int(fields["completed_chunks"]),
		Iterations:      int(fields["iterations"]),
		Wins:            int(fields["wins"]),
		Ties:            int(fields["ties"]),
		Losses:          int(fields["losses"]),
		EquityMicros:    fields["equity_micros"],
	}
	if snapshot.Iterations > 0 {
		snapshot.Equity = float64(snapshot.EquityMicros) / float64(snapshot.Iterations*1_000_000)
	}
	return snapshot, true, nil
}

func asInt64(value any) int64 {
	switch v := value.(type) {
	case int64:
		return v
	case string:
		n, _ := strconv.ParseInt(v, 10, 64)
		return n
	default:
		return 0
	}
}

func dial(ctx context.Context, addr string, useTLS bool, timeout time.Duration) (net.Conn, error) {
	dialer := net.Dialer{Timeout: timeout}
	if useTLS {
		return tls.DialWithDialer(&dialer, "tcp", addr, &tls.Config{MinVersion: tls.VersionTLS12})
	}
	return dialer.DialContext(ctx, "tcp", addr)
}
