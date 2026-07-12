package worker

import (
	"encoding/json"
	"fmt"

	"poker-engine/internal/poker"
)

type ChunkMessage struct {
	HandID         string   `json:"hand_id"`
	BoardVersion   int      `json:"board_version"`
	ChunkID        int      `json:"chunk_id"`
	ExpectedChunks int      `json:"expected_chunks"`
	Hero           []string `json:"hero"`
	Board          []string `json:"board"`
	Opponents      int      `json:"opponents"`
	Iterations     int      `json:"iterations"`
	Seed           int64    `json:"seed"`
}

func DecodeChunkMessage(body []byte) (ChunkMessage, error) {
	var msg ChunkMessage
	if err := json.Unmarshal(body, &msg); err != nil {
		return ChunkMessage{}, fmt.Errorf("decode chunk message: %w", err)
	}
	if err := msg.Validate(); err != nil {
		return ChunkMessage{}, err
	}
	return msg, nil
}

func (m ChunkMessage) Validate() error {
	if m.HandID == "" {
		return poker.ErrInvalidInput("hand_id is required")
	}
	if m.BoardVersion < 0 {
		return poker.ErrInvalidInput("board_version cannot be negative")
	}
	if m.ChunkID < 0 {
		return poker.ErrInvalidInput("chunk_id cannot be negative")
	}
	if m.ExpectedChunks <= 0 {
		return poker.ErrInvalidInput("expected_chunks must be positive")
	}
	if m.ChunkID >= m.ExpectedChunks {
		return poker.ErrInvalidInput("chunk_id must be less than expected_chunks")
	}
	if len(m.Hero) != 2 {
		return poker.ErrInvalidInput("hero must contain exactly two cards")
	}
	if len(m.Board) > 5 {
		return poker.ErrInvalidInput("board cannot contain more than five cards")
	}
	if m.Opponents <= 0 {
		return poker.ErrInvalidInput("opponents must be positive")
	}
	if m.Iterations <= 0 {
		return poker.ErrInvalidInput("iterations must be positive")
	}
	if m.Seed == 0 {
		return poker.ErrInvalidInput("seed must be non-zero")
	}
	return nil
}

func (m ChunkMessage) Chunk() poker.SimulationChunk {
	return poker.SimulationChunk{
		HandID:       m.HandID,
		BoardVersion: m.BoardVersion,
		ChunkID:      m.ChunkID,
		Iterations:   m.Iterations,
		Seed:         m.Seed,
	}
}

func (m ChunkMessage) SimulationRequest() (poker.SimulationRequest, error) {
	hero, err := parseCardList(m.Hero)
	if err != nil {
		return poker.SimulationRequest{}, fmt.Errorf("parse hero: %w", err)
	}
	board, err := parseCardList(m.Board)
	if err != nil {
		return poker.SimulationRequest{}, fmt.Errorf("parse board: %w", err)
	}
	return poker.SimulationRequest{
		Hero:      hero,
		Board:     board,
		Opponents: m.Opponents,
	}, nil
}

func parseCardList(values []string) ([]poker.Card, error) {
	cards := make([]poker.Card, 0, len(values))
	seen := make(map[poker.Card]struct{}, len(values))
	for _, value := range values {
		card, err := poker.ParseCard(value)
		if err != nil {
			return nil, err
		}
		if _, ok := seen[card]; ok {
			return nil, fmt.Errorf("duplicate card %s", card)
		}
		seen[card] = struct{}{}
		cards = append(cards, card)
	}
	return cards, nil
}
