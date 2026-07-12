package main

import (
	"context"
	"encoding/json"
	"testing"

	"poker-engine/internal/worker"
)

type fakeReader struct {
	snapshot worker.AggregateSnapshot
	found    bool
	err      error
}

func (f fakeReader) GetSnapshot(context.Context, string, int) (worker.AggregateSnapshot, bool, error) {
	return f.snapshot, f.found, f.err
}

func TestHandleInvocationReturnsCompleteResult(t *testing.T) {
	event := APIGatewayV2Event{
		PathParameters:        map[string]string{"hand_id": "hand-aa"},
		QueryStringParameters: map[string]string{"board_version": "3"},
	}
	payload, err := json.Marshal(event)
	if err != nil {
		t.Fatal(err)
	}

	response := handleInvocation(context.Background(), fakeReader{
		found: true,
		snapshot: worker.AggregateSnapshot{
			HandID:          "hand-aa",
			BoardVersion:    3,
			ExpectedChunks:  10,
			CompletedChunks: 10,
			Iterations:      100_000,
			Wins:            75_000,
			Ties:            1_000,
			Losses:          24_000,
			EquityMicros:    75500000000,
			Equity:          0.755,
		},
	}, payload)

	if response.StatusCode != 200 {
		t.Fatalf("status=%d body=%s", response.StatusCode, response.Body)
	}
	var body map[string]any
	if err := json.Unmarshal([]byte(response.Body), &body); err != nil {
		t.Fatal(err)
	}
	if body["status"] != "complete" || body["complete"] != true {
		t.Fatalf("unexpected body: %#v", body)
	}
	if body["equity_percent"].(float64) != 75.5 {
		t.Fatalf("equity_percent=%v", body["equity_percent"])
	}
}

func TestHandleInvocationReturnsNotFound(t *testing.T) {
	event := APIGatewayV2Event{PathParameters: map[string]string{"hand_id": "missing"}}
	payload, err := json.Marshal(event)
	if err != nil {
		t.Fatal(err)
	}

	response := handleInvocation(context.Background(), fakeReader{found: false}, payload)
	if response.StatusCode != 404 {
		t.Fatalf("status=%d body=%s", response.StatusCode, response.Body)
	}
}
