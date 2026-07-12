package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"

	"poker-engine/internal/worker"
)

func main() {
	messagePath := flag.String("message", "", "path to a worker chunk JSON message; reads stdin when empty")
	flag.Parse()

	body, err := readBody(*messagePath)
	if err != nil {
		log.Fatal(err)
	}

	processor := worker.NewProcessor(worker.NewInMemoryAggregator())
	result, err := processor.ProcessBody(context.Background(), body)
	if err != nil {
		log.Fatal(err)
	}

	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	if err := enc.Encode(result); err != nil {
		log.Fatal(err)
	}
}

func readBody(path string) ([]byte, error) {
	if path == "" {
		return os.ReadFile("/dev/stdin")
	}
	body, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read message file: %w", err)
	}
	return body, nil
}
