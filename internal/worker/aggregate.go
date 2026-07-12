package worker

import (
	"context"
	"fmt"
	"sync"

	"poker-engine/internal/poker"
)

type AggregateDelta struct {
	HandID         string
	BoardVersion   int
	ChunkID        int
	ExpectedChunks int
	Iterations     int
	Wins           int
	Ties           int
	Losses         int
	EquityMicros   int64
}

type AggregateSnapshot struct {
	HandID          string
	BoardVersion    int
	ExpectedChunks  int
	CompletedChunks int
	Iterations      int
	Wins            int
	Ties            int
	Losses          int
	EquityMicros    int64
	Equity          float64
}

type Aggregator interface {
	ApplyChunkResult(ctx context.Context, delta AggregateDelta) (applied bool, snapshot AggregateSnapshot, err error)
}

type InMemoryAggregator struct {
	mu        sync.Mutex
	seen      map[string]struct{}
	snapshots map[string]AggregateSnapshot
}

func NewInMemoryAggregator() *InMemoryAggregator {
	return &InMemoryAggregator{
		seen:      make(map[string]struct{}),
		snapshots: make(map[string]AggregateSnapshot),
	}
}

func (a *InMemoryAggregator) ApplyChunkResult(ctx context.Context, delta AggregateDelta) (bool, AggregateSnapshot, error) {
	if err := ctx.Err(); err != nil {
		return false, AggregateSnapshot{}, err
	}
	if delta.HandID == "" {
		return false, AggregateSnapshot{}, poker.ErrInvalidInput("hand id is required")
	}
	if delta.BoardVersion < 0 || delta.ChunkID < 0 {
		return false, AggregateSnapshot{}, poker.ErrInvalidInput("board version and chunk id must be non-negative")
	}
	if delta.ExpectedChunks <= 0 || delta.ChunkID >= delta.ExpectedChunks {
		return false, AggregateSnapshot{}, poker.ErrInvalidInput("invalid expected chunk count")
	}
	if delta.Iterations <= 0 {
		return false, AggregateSnapshot{}, poker.ErrInvalidInput("iterations must be positive")
	}

	a.mu.Lock()
	defer a.mu.Unlock()

	idempotencyKey := chunkKey(delta.HandID, delta.BoardVersion, delta.ChunkID)
	aggregateKey := aggregateKey(delta.HandID, delta.BoardVersion)
	if _, ok := a.seen[idempotencyKey]; ok {
		return false, a.snapshots[aggregateKey], nil
	}

	a.seen[idempotencyKey] = struct{}{}
	snapshot := a.snapshots[aggregateKey]
	snapshot.HandID = delta.HandID
	snapshot.BoardVersion = delta.BoardVersion
	snapshot.ExpectedChunks = delta.ExpectedChunks
	snapshot.CompletedChunks++
	snapshot.Iterations += delta.Iterations
	snapshot.Wins += delta.Wins
	snapshot.Ties += delta.Ties
	snapshot.Losses += delta.Losses
	snapshot.EquityMicros += delta.EquityMicros
	if snapshot.Iterations > 0 {
		snapshot.Equity = float64(snapshot.EquityMicros) / float64(snapshot.Iterations*1_000_000)
	}
	a.snapshots[aggregateKey] = snapshot

	return true, snapshot, nil
}

func NewAggregateDelta(msg ChunkMessage, result poker.SimulationResult) AggregateDelta {
	return AggregateDelta{
		HandID:         msg.HandID,
		BoardVersion:   msg.BoardVersion,
		ChunkID:        msg.ChunkID,
		ExpectedChunks: msg.ExpectedChunks,
		Iterations:     result.Iterations,
		Wins:           result.Wins,
		Ties:           result.Ties,
		Losses:         result.Losses,
		EquityMicros:   result.EquityMicros,
	}
}

func chunkKey(handID string, boardVersion int, chunkID int) string {
	return fmt.Sprintf("processed:%s:%d:%d", handID, boardVersion, chunkID)
}

func aggregateKey(handID string, boardVersion int) string {
	return fmt.Sprintf("aggregate:%s:%d", handID, boardVersion)
}
