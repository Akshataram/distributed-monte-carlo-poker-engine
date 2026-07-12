package worker

import (
	"context"
	"encoding/json"
	"testing"

	"poker-engine/internal/poker"
)

func TestProcessorAppliesChunkOnce(t *testing.T) {
	msg := ChunkMessage{
		HandID:         "hand-aa",
		BoardVersion:   0,
		ChunkID:        0,
		ExpectedChunks: 1,
		Hero:           []string{"As", "Ah"},
		Board:          nil,
		Opponents:      1,
		Iterations:     10_000,
		Seed:           42,
	}
	body, err := json.Marshal(msg)
	if err != nil {
		t.Fatal(err)
	}

	processor := NewProcessor(NewInMemoryAggregator())
	first, err := processor.ProcessBody(context.Background(), body)
	if err != nil {
		t.Fatal(err)
	}
	second, err := processor.ProcessBody(context.Background(), body)
	if err != nil {
		t.Fatal(err)
	}

	if !first.Applied {
		t.Fatalf("first processing should apply counters")
	}
	if second.Applied {
		t.Fatalf("duplicate processing should not apply counters")
	}
	if first.State.Iterations != second.State.Iterations {
		t.Fatalf("duplicate changed aggregate iterations: first=%d second=%d", first.State.Iterations, second.State.Iterations)
	}
	if second.State.CompletedChunks != 1 {
		t.Fatalf("completed chunks=%d want=1", second.State.CompletedChunks)
	}
}

func TestProcessorRejectsInvalidMessage(t *testing.T) {
	processor := NewProcessor(NewInMemoryAggregator())
	_, err := processor.ProcessBody(context.Background(), []byte(`{"hand_id":"x","expected_chunks":1,"hero":["As"],"opponents":1,"iterations":100,"seed":1}`))
	if err == nil {
		t.Fatalf("expected invalid hero error")
	}
}

func TestMessagesFromPlanCarriesExpectedChunks(t *testing.T) {
	hero := mustParseCards(t, "As Ah")
	board := mustParseCards(t, "Ks Qs Js")
	chunks, err := poker.BuildChunkPlan(poker.ChunkPlanRequest{
		HandID:             "hand-aa",
		BoardVersion:       3,
		TotalIterations:    25_000,
		IterationsPerChunk: 10_000,
		BaseSeed:           42,
	})
	if err != nil {
		t.Fatal(err)
	}

	messages := MessagesFromPlan(hero, board, 1, chunks)
	if len(messages) != 3 {
		t.Fatalf("messages=%d want=3", len(messages))
	}
	if messages[0].ExpectedChunks != 3 || messages[2].Iterations != 5_000 {
		t.Fatalf("bad chunk message metadata: %#v", messages)
	}
	if messages[0].Hero[0] != "As" || messages[0].Board[2] != "Js" {
		t.Fatalf("cards were not serialized correctly: %#v", messages[0])
	}
}

func mustParseCards(t *testing.T, input string) []poker.Card {
	t.Helper()
	cards, err := poker.ParseCards(input)
	if err != nil {
		t.Fatal(err)
	}
	return cards
}
