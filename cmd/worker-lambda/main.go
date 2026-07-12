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

type SQSEvent struct {
	Records []SQSMessage `json:"Records"`
}

type SQSMessage struct {
	MessageID string `json:"messageId"`
	Body      string `json:"body"`
}

type BatchResponse struct {
	BatchItemFailures []BatchItemFailure `json:"batchItemFailures"`
}

type BatchItemFailure struct {
	ItemIdentifier string `json:"itemIdentifier"`
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
		TTL:      durationEnv("AGGREGATE_TTL_SECONDS", 86400) * time.Second,
		Timeout:  durationEnv("REDIS_TIMEOUT_SECONDS", 2) * time.Second,
	})
	if err != nil {
		log.Fatal(err)
	}

	processor := worker.NewProcessor(aggregator)
	runtimeAPI := requiredEnv("AWS_LAMBDA_RUNTIME_API")
	for {
		inv, err := nextInvocation(runtimeAPI)
		if err != nil {
			log.Fatal(err)
		}
		response, err := handleInvocation(context.Background(), processor, inv.payload)
		if err != nil {
			postInvocationError(runtimeAPI, inv.requestID, err)
			continue
		}
		if err := postInvocationResponse(runtimeAPI, inv.requestID, response); err != nil {
			log.Fatal(err)
		}
	}
}

func handleInvocation(ctx context.Context, processor worker.Processor, payload []byte) (BatchResponse, error) {
	var event SQSEvent
	if err := json.Unmarshal(payload, &event); err != nil {
		return BatchResponse{}, err
	}
	response := BatchResponse{}
	for _, record := range event.Records {
		result, err := processor.ProcessBody(ctx, []byte(record.Body))
		if err != nil {
			log.Printf("message_id=%s applied=false error=%v", record.MessageID, err)
			response.BatchItemFailures = append(response.BatchItemFailures, BatchItemFailure{ItemIdentifier: record.MessageID})
			continue
		}
		log.Printf(
			"message_id=%s hand_id=%s board_version=%d chunk_id=%d applied=%t completed=%d/%d equity=%.6f",
			record.MessageID,
			result.Message.HandID,
			result.Message.BoardVersion,
			result.Message.ChunkID,
			result.Applied,
			result.State.CompletedChunks,
			result.State.ExpectedChunks,
			result.State.Equity,
		)
	}
	return response, nil
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

func postInvocationResponse(runtimeAPI string, requestID string, response BatchResponse) error {
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

func postInvocationError(runtimeAPI string, requestID string, err error) {
	body, _ := json.Marshal(map[string]string{
		"errorMessage": err.Error(),
		"errorType":    "WorkerError",
	})
	url := fmt.Sprintf("http://%s/2018-06-01/runtime/invocation/%s/error", runtimeAPI, requestID)
	resp, postErr := http.Post(url, "application/json", bytes.NewReader(body))
	if postErr != nil {
		log.Printf("failed to post invocation error: %v", postErr)
		return
	}
	defer resp.Body.Close()
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
