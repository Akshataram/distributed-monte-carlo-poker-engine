package poker

import (
	"encoding/binary"
	"fmt"
	"hash/fnv"
)

type ChunkPlanRequest struct {
	HandID             string
	BoardVersion       int
	TotalIterations    int
	IterationsPerChunk int
	BaseSeed           int64
}

type SimulationChunk struct {
	HandID       string
	BoardVersion int
	ChunkID      int
	Iterations   int
	Seed         int64
}

func (c SimulationChunk) IdempotencyKey() string {
	return fmt.Sprintf("%s:%d:%d", c.HandID, c.BoardVersion, c.ChunkID)
}

func BuildChunkPlan(req ChunkPlanRequest) ([]SimulationChunk, error) {
	if req.HandID == "" {
		return nil, ErrInvalidInput("hand id is required")
	}
	if req.BoardVersion < 0 {
		return nil, ErrInvalidInput("board version cannot be negative")
	}
	if req.TotalIterations <= 0 {
		return nil, ErrInvalidInput("total iterations must be positive")
	}
	if req.IterationsPerChunk <= 0 {
		return nil, ErrInvalidInput("iterations per chunk must be positive")
	}
	if req.BaseSeed == 0 {
		return nil, ErrInvalidInput("base seed must be non-zero for deterministic chunking")
	}

	chunkCount := (req.TotalIterations + req.IterationsPerChunk - 1) / req.IterationsPerChunk
	chunks := make([]SimulationChunk, 0, chunkCount)
	remaining := req.TotalIterations

	for chunkID := 0; chunkID < chunkCount; chunkID++ {
		iterations := req.IterationsPerChunk
		if remaining < iterations {
			iterations = remaining
		}
		chunks = append(chunks, SimulationChunk{
			HandID:       req.HandID,
			BoardVersion: req.BoardVersion,
			ChunkID:      chunkID,
			Iterations:   iterations,
			Seed:         deriveChunkSeed(req.HandID, req.BoardVersion, chunkID, req.BaseSeed),
		})
		remaining -= iterations
	}

	return chunks, nil
}

func SimulateChunk(base SimulationRequest, chunk SimulationChunk) (SimulationResult, error) {
	if chunk.Iterations <= 0 {
		return SimulationResult{}, ErrInvalidInput("chunk iterations must be positive")
	}
	if chunk.Seed == 0 {
		return SimulationResult{}, ErrInvalidInput("chunk seed must be non-zero")
	}

	base.Iterations = chunk.Iterations
	base.Seed = chunk.Seed
	return Simulate(base)
}

func deriveChunkSeed(handID string, boardVersion int, chunkID int, baseSeed int64) int64 {
	h := fnv.New64a()
	_, _ = h.Write([]byte(handID))
	writeInt64(h, int64(boardVersion))
	writeInt64(h, int64(chunkID))
	writeInt64(h, baseSeed)

	seed := int64(h.Sum64() & 0x7fffffffffffffff)
	if seed == 0 {
		return 1
	}
	return seed
}

func writeInt64(h interface{ Write([]byte) (int, error) }, value int64) {
	var buf [8]byte
	binary.LittleEndian.PutUint64(buf[:], uint64(value))
	_, _ = h.Write(buf[:])
}
