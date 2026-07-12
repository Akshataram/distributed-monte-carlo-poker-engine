package main

import (
	"context"
	"encoding/json"
	"testing"

	"poker-engine/internal/worker"
)

func TestHandleInvocationReturnsPartialBatchFailures(t *testing.T) {
	valid := worker.ChunkMessage{
		HandID:         "hand-aa",
		BoardVersion:   0,
		ChunkID:        0,
		ExpectedChunks: 1,
		Hero:           []string{"As", "Ah"},
		Board:          nil,
		Opponents:      1,
		Iterations:     100,
		Seed:           42,
	}
	body, err := json.Marshal(valid)
	if err != nil {
		t.Fatal(err)
	}
	event := SQSEvent{Records: []SQSMessage{
		{MessageID: "ok", Body: string(body)},
		{MessageID: "bad", Body: `{"hand_id":"x"}`},
	}}
	payload, err := json.Marshal(event)
	if err != nil {
		t.Fatal(err)
	}

	response, err := handleInvocation(context.Background(), worker.NewProcessor(worker.NewInMemoryAggregator()), payload)
	if err != nil {
		t.Fatal(err)
	}
	if len(response.BatchItemFailures) != 1 || response.BatchItemFailures[0].ItemIdentifier != "bad" {
		t.Fatalf("unexpected batch failures: %#v", response)
	}
}
