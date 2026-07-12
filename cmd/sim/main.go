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
	result, err := poker.Simulate(poker.SimulationRequest{
		Hero:       hero,
		Board:      board,
		Opponents:  *opponents,
		Iterations: *iterations,
		Seed:       *seed,
	})
	if err != nil {
		log.Fatal(err)
	}

	elapsed := time.Since(start)
	fmt.Printf("hero=%s board=%s opponents=%d iterations=%d seed=%d\n", *heroArg, blank(*boardArg, "(none)"), *opponents, result.Iterations, *seed)
	fmt.Printf("wins=%d ties=%d losses=%d\n", result.Wins, result.Ties, result.Losses)
	fmt.Printf("equity=%.4f%% elapsed=%s sims/sec=%.0f\n", result.Equity*100, elapsed.Round(time.Millisecond), float64(result.Iterations)/elapsed.Seconds())
}

func blank(s, fallback string) string {
	if s == "" {
		return fallback
	}
	return s
}
