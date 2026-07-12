package worker

import "poker-engine/internal/poker"

func MessagesFromPlan(hero []poker.Card, board []poker.Card, opponents int, chunks []poker.SimulationChunk) []ChunkMessage {
	messages := make([]ChunkMessage, 0, len(chunks))
	expectedChunks := len(chunks)
	for _, chunk := range chunks {
		messages = append(messages, ChunkMessage{
			HandID:         chunk.HandID,
			BoardVersion:   chunk.BoardVersion,
			ChunkID:        chunk.ChunkID,
			ExpectedChunks: expectedChunks,
			Hero:           cardsToStrings(hero),
			Board:          cardsToStrings(board),
			Opponents:      opponents,
			Iterations:     chunk.Iterations,
			Seed:           chunk.Seed,
		})
	}
	return messages
}

func cardsToStrings(cards []poker.Card) []string {
	out := make([]string, 0, len(cards))
	for _, card := range cards {
		out = append(out, card.String())
	}
	return out
}
