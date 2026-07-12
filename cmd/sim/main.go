package main

import (
	"flag"
	"fmt"
	"log"
	"time"

	"poker-engine/internal/poker"
)

func main() {
	heroArg := flag.String("hero", "As Ah", "two hero hole cards, e.g. \"As Ah\"")
	boardArg := flag.String("board", "", "known community cards, e.g. \"Ks Qs Js\"")
	opponents := flag.Int("opponents", 1, "number of random opponents")
	iterations := flag.Int("n", 100000, "number of Monte Carlo simulations")
	chunkSize := flag.Int("chunk-size", 0, "optional deterministic iterations per worker chunk")
	handID := flag.String("hand-id", "local-hand", "stable hand id used for deterministic chunking")
	boardVersion := flag.Int("board-version", 0, "board version used for deterministic chunking")
	seed := flag.Int64("seed", 42, "random seed; use 0 for time-based seed")
	flag.Parse()

	hero, err := poker.ParseCards(*heroArg)
	if err != nil {
		log.Fatal(err)
	}
	board, err := poker.ParseCards(*boardArg)
	if err != nil {
		log.Fatal(err)
	}
	if *seed == 0 {
		*seed = time.Now().UnixNano()
	}

	start := time.Now()
	base := poker.SimulationRequest{
		Hero:       hero,
		Board:      board,
		Opponents:  *opponents,
		Iterations: *iterations,
		Seed:       *seed,
	}

	var result poker.SimulationResult
	var chunks []poker.SimulationChunk
	if *chunkSize > 0 {
		chunks, err = poker.BuildChunkPlan(poker.ChunkPlanRequest{
			HandID:             *handID,
			BoardVersion:       *boardVersion,
			TotalIterations:    *iterations,
			IterationsPerChunk: *chunkSize,
			BaseSeed:           *seed,
		})
		if err != nil {
			log.Fatal(err)
		}
		partialResults := make([]poker.SimulationResult, 0, len(chunks))
		for _, chunk := range chunks {
			partial, err := poker.SimulateChunk(base, chunk)
			if err != nil {
				log.Fatal(err)
			}
			partialResults = append(partialResults, partial)
		}
		result = poker.MergeResults(partialResults...)
	} else {
		result, err = poker.Simulate(base)
	}
	if err != nil {
		log.Fatal(err)
	}

	elapsed := time.Since(start)
	fmt.Printf("hero=%s board=%s opponents=%d iterations=%d seed=%d\n", *heroArg, blank(*boardArg, "(none)"), *opponents, result.Iterations, *seed)
	if len(chunks) > 0 {
		fmt.Printf("hand_id=%s board_version=%d chunks=%d chunk_size=%d\n", *handID, *boardVersion, len(chunks), *chunkSize)
		fmt.Printf("first_chunk_key=%s first_chunk_seed=%d\n", chunks[0].IdempotencyKey(), chunks[0].Seed)
	}
	fmt.Printf("wins=%d ties=%d losses=%d\n", result.Wins, result.Ties, result.Losses)
	fmt.Printf("equity=%.4f%% equity_micros=%d elapsed=%s sims/sec=%.0f\n", result.Equity*100, result.EquityMicros, elapsed.Round(time.Millisecond), float64(result.Iterations)/elapsed.Seconds())
}

func blank(s, fallback string) string {
	if s == "" {
		return fallback
	}
	return s
}
