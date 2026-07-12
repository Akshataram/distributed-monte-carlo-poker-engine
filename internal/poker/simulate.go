package poker

import (
	"math/rand"
	"time"
)

type SimulationRequest struct {
	Hero       []Card
	Board      []Card
	Opponents  int
	Iterations int
	Seed       int64
}

type SimulationResult struct {
	Iterations   int
	Wins         int
	Ties         int
	Losses       int
	EquityMicros int64
	Equity       float64
}

func Simulate(req SimulationRequest) (SimulationResult, error) {
	if req.Opponents <= 0 {
		req.Opponents = 1
	}
	if req.Iterations <= 0 {
		req.Iterations = 100_000
	}
	if req.Seed == 0 {
		req.Seed = time.Now().UnixNano()
	}
	if len(req.Hero) != 2 {
		return SimulationResult{}, ErrInvalidInput("hero must contain exactly two cards")
	}
	if len(req.Board) > 5 {
		return SimulationResult{}, ErrInvalidInput("board cannot contain more than five cards")
	}

	deck, err := RemoveKnown(NewDeck(), req.Hero, req.Board)
	if err != nil {
		return SimulationResult{}, err
	}

	needed := req.Opponents*2 + (5 - len(req.Board))
	if needed > len(deck) {
		return SimulationResult{}, ErrInvalidInput("not enough cards left for opponents and board")
	}

	rng := rand.New(rand.NewSource(req.Seed))
	scratch := make([]Card, len(deck))
	heroCards := make([]Card, 0, 7)
	oppCards := make([]Card, 7)

	var result SimulationResult

	for i := 0; i < req.Iterations; i++ {
		copy(scratch, deck)
		partialShuffle(scratch, needed, rng)

		draw := 0
		board := make([]Card, 0, 5)
		board = append(board, req.Board...)
		missingBoard := 5 - len(req.Board)
		board = append(board, scratch[draw:draw+missingBoard]...)
		draw += missingBoard

		heroCards = heroCards[:0]
		heroCards = append(heroCards, req.Hero...)
		heroCards = append(heroCards, board...)
		heroValue := Evaluate(heroCards)

		heroBest := true
		tiedBest := 0
		for opp := 0; opp < req.Opponents; opp++ {
			oppCards = oppCards[:0]
			oppCards = append(oppCards, scratch[draw], scratch[draw+1])
			draw += 2
			oppCards = append(oppCards, board...)
			oppValue := Evaluate(oppCards)

			if oppValue > heroValue {
				heroBest = false
				break
			}
			if oppValue == heroValue {
				tiedBest++
			}
		}

		result.Iterations++
		switch {
		case !heroBest:
			result.Losses++
		case tiedBest > 0:
			result.Ties++
			result.EquityMicros += int64(1_000_000 / (tiedBest + 1))
		default:
			result.Wins++
			result.EquityMicros += 1_000_000
		}
	}

	result.Equity = float64(result.EquityMicros) / float64(result.Iterations*1_000_000)
	return result, nil
}

func MergeResults(results ...SimulationResult) SimulationResult {
	var merged SimulationResult
	for _, result := range results {
		merged.Iterations += result.Iterations
		merged.Wins += result.Wins
		merged.Ties += result.Ties
		merged.Losses += result.Losses
		merged.EquityMicros += result.EquityMicros
	}
	if merged.Iterations > 0 {
		merged.Equity = float64(merged.EquityMicros) / float64(merged.Iterations*1_000_000)
	}
	return merged
}

func partialShuffle(cards []Card, n int, rng *rand.Rand) {
	for i := 0; i < n; i++ {
		j := i + rng.Intn(len(cards)-i)
		cards[i], cards[j] = cards[j], cards[i]
	}
}

type ErrInvalidInput string

func (e ErrInvalidInput) Error() string {
	return string(e)
}
