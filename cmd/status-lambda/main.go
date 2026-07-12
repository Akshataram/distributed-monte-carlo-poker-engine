package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"time"

	"poker-engine/internal/redisagg"
	"poker-engine/internal/worker"
)

type APIGatewayV2Event struct {
	RawPath               string            `json:"rawPath"`
	PathParameters        map[string]string `json:"pathParameters"`
	QueryStringParameters map[string]string `json:"queryStringParameters"`
}

type APIResponse struct {
	StatusCode int               `json:"statusCode"`
	Headers    map[string]string `json:"headers"`
	Body       string            `json:"body"`
}

type invocation struct {
	requestID string
	payload   []byte
}

func main() {
	aggregator, err := redisagg.New(redisagg.Config{
		Addr:     requiredEnv("REDIS_ADDR"),
		Username: os.Getenv("REDIS_USERNAME"),
		Password: os.Getenv("REDIS_PASSWORD"),
		UseTLS:   boolEnv("REDIS_TLS", false),
		Timeout:  durationEnv("REDIS_TIMEOUT_SECONDS", 2) * time.Second,
	})
	if err != nil {
		log.Fatal(err)
	}

	runtimeAPI := requiredEnv("AWS_LAMBDA_RUNTIME_API")
	for {
		inv, err := nextInvocation(runtimeAPI)
		if err != nil {
			log.Fatal(err)
		}
		response := handleInvocation(context.Background(), aggregator, inv.payload)
		if err := postInvocationResponse(runtimeAPI, inv.requestID, response); err != nil {
			log.Fatal(err)
		}
	}
}

func handleInvocation(ctx context.Context, aggregator interface {
	GetSnapshot(context.Context, string, int) (worker.AggregateSnapshot, bool, error)
}, payload []byte) APIResponse {
	var event APIGatewayV2Event
	if err := json.Unmarshal(payload, &event); err != nil {
		return jsonResponse(400, map[string]string{"error": "invalid request event"})
	}

	handID := event.PathParameters["hand_id"]
	if handID == "" {
		return jsonResponse(400, map[string]string{"error": "hand_id path parameter is required"})
	}
	boardVersion, err := parseBoardVersion(event.QueryStringParameters)
	if err != nil {
		return jsonResponse(400, map[string]string{"error": err.Error()})
	}

	snapshot, found, err := aggregator.GetSnapshot(ctx, handID, boardVersion)
	if err != nil {
		log.Printf("hand_id=%s board_version=%d error=%v", handID, boardVersion, err)
		return jsonResponse(500, map[string]string{"error": "failed to read aggregate status"})
	}
	if !found {
		return jsonResponse(404, map[string]any{
			"hand_id":       handID,
			"board_version": boardVersion,
			"status":        "not_found",
		})
	}

	completed := snapshot.CompletedChunks >= snapshot.ExpectedChunks && snapshot.ExpectedChunks > 0
	status := "running"
	if completed {
		status = "complete"
	}
	progress := 0.0
	if snapshot.ExpectedChunks > 0 {
		progress = float64(snapshot.CompletedChunks) / float64(snapshot.ExpectedChunks)
	}

	return jsonResponse(200, map[string]any{
		"hand_id":          snapshot.HandID,
		"board_version":    snapshot.BoardVersion,
		"status":           status,
		"complete":         completed,
		"progress":         progress,
		"expected_chunks":  snapshot.ExpectedChunks,
		"completed_chunks": snapshot.CompletedChunks,
		"iterations":       snapshot.Iterations,
		"wins":             snapshot.Wins,
		"ties":             snapshot.Ties,
		"losses":           snapshot.Losses,
		"equity":           snapshot.Equity,
		"equity_percent":   snapshot.Equity * 100,
		"equity_micros":    snapshot.EquityMicros,
	})
}

func parseBoardVersion(query map[string]string) (int, error) {
	raw := query["board_version"]
	if raw == "" {
		return 0, nil
	}
	value, err := strconv.Atoi(raw)
	if err != nil || value < 0 {
		return 0, fmt.Errorf("board_version must be a non-negative integer")
	}
	return value, nil
}

func jsonResponse(statusCode int, payload any) APIResponse {
	body, _ := json.Marshal(payload)
	return APIResponse{
		StatusCode: statusCode,
		Headers:    map[string]string{"content-type": "application/json"},
		Body:       string(body),
	}
}

func nextInvocation(runtimeAPI string) (invocation, error) {
	url := fmt.Sprintf("http://%s/2018-06-01/runtime/invocation/next", runtimeAPI)
	resp, err := http.Get(url)
	if err != nil {
		return invocation{}, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return invocation{}, err
	}
	requestID := resp.Header.Get("Lambda-Runtime-Aws-Request-Id")
	if requestID == "" {
		return invocation{}, fmt.Errorf("lambda runtime did not return request id")
	}
	return invocation{requestID: requestID, payload: body}, nil
}

func postInvocationResponse(runtimeAPI string, requestID string, response APIResponse) error {
	body, err := json.Marshal(response)
	if err != nil {
		return err
	}
	url := fmt.Sprintf("http://%s/2018-06-01/runtime/invocation/%s/response", runtimeAPI, requestID)
	resp, err := http.Post(url, "application/json", bytes.NewReader(body))
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return fmt.Errorf("runtime response failed: %s", resp.Status)
	}
	return nil
}

func requiredEnv(key string) string {
	value := os.Getenv(key)
	if value == "" {
		log.Fatalf("%s is required", key)
	}
	return value
}

func boolEnv(key string, fallback bool) bool {
	value := os.Getenv(key)
	if value == "" {
		return fallback
	}
	parsed, err := strconv.ParseBool(value)
	if err != nil {
		log.Fatalf("invalid boolean %s=%q", key, value)
	}
	return parsed
}

func durationEnv(key string, fallback int64) time.Duration {
	value := os.Getenv(key)
	if value == "" {
		return time.Duration(fallback)
	}
	parsed, err := strconv.ParseInt(value, 10, 64)
	if err != nil {
		log.Fatalf("invalid integer %s=%q", key, value)
	}
	return time.Duration(parsed)
}
