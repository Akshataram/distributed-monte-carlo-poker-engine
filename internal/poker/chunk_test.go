package poker

import "testing"

func TestBuildChunkPlanIsDeterministic(t *testing.T) {
	req := ChunkPlanRequest{
		HandID:             "hand-123",
		BoardVersion:       2,
		TotalIterations:    25_001,
		IterationsPerChunk: 10_000,
		BaseSeed:           42,
	}

	first, err := BuildChunkPlan(req)
	if err != nil {
		t.Fatal(err)
	}
	second, err := BuildChunkPlan(req)
	if err != nil {
		t.Fatal(err)
	}

	if len(first) != 3 {
		t.Fatalf("chunks=%d want=3", len(first))
	}
	if first[2].Iterations != 5_001 {
		t.Fatalf("tail iterations=%d want=5001", first[2].Iterations)
	}
	for i := range first {
		if first[i] != second[i] {
			t.Fatalf("chunk %d changed across deterministic plans: %#v != %#v", i, first[i], second[i])
		}
		if first[i].IdempotencyKey() == "" {
			t.Fatalf("chunk %d has empty idempotency key", i)
		}
	}
}

func TestChunkSeedsChangeAcrossBoardVersions(t *testing.T) {
	flop, err := BuildChunkPlan(ChunkPlanRequest{
		HandID:             "hand-123",
		BoardVersion:       3,
		TotalIterations:    10_000,
		IterationsPerChunk: 10_000,
		BaseSeed:           42,
	})
	if err != nil {
		t.Fatal(err)
	}
	turn, err := BuildChunkPlan(ChunkPlanRequest{
		HandID:             "hand-123",
		BoardVersion:       4,
		TotalIterations:    10_000,
		IterationsPerChunk: 10_000,
		BaseSeed:           42,
	})
	if err != nil {
		t.Fatal(err)
	}

	if flop[0].Seed == turn[0].Seed {
		t.Fatalf("seed must change when board version changes")
	}
}

func TestSimulateChunkCanBeMerged(t *testing.T) {
	hero := MustParseCards("As Ah")
	chunks, err := BuildChunkPlan(ChunkPlanRequest{
		HandID:             "hand-aa",
		BoardVersion:       0,
		TotalIterations:    30_000,
		IterationsPerChunk: 10_000,
		BaseSeed:           42,
	})
	if err != nil {
		t.Fatal(err)
	}

	results := make([]SimulationResult, 0, len(chunks))
	for _, chunk := range chunks {
		result, err := SimulateChunk(SimulationRequest{Hero: hero, Opponents: 1}, chunk)
		if err != nil {
			t.Fatal(err)
		}
		results = append(results, result)
	}

	merged := MergeResults(results...)
	if merged.Iterations != 30_000 {
		t.Fatalf("iterations=%d want=30000", merged.Iterations)
	}
	if merged.Wins+merged.Ties+merged.Losses != merged.Iterations {
		t.Fatalf("terminal outcomes do not add up: %#v", merged)
	}
	if merged.Equity < 0.80 || merged.Equity > 0.90 {
		t.Fatalf("AA heads-up equity=%f, expected a sane Monte Carlo range", merged.Equity)
	}
}
