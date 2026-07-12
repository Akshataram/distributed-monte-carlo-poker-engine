package worker

import (
	"context"

	"poker-engine/internal/poker"
)

type ProcessResult struct {
	Message ChunkMessage
	Poker   poker.SimulationResult
	Applied bool
	State   AggregateSnapshot
}

type Processor struct {
	Aggregator Aggregator
}

func NewProcessor(aggregator Aggregator) Processor {
	return Processor{Aggregator: aggregator}
}

func (p Processor) ProcessBody(ctx context.Context, body []byte) (ProcessResult, error) {
	msg, err := DecodeChunkMessage(body)
	if err != nil {
		return ProcessResult{}, err
	}
	return p.ProcessMessage(ctx, msg)
}

func (p Processor) ProcessMessage(ctx context.Context, msg ChunkMessage) (ProcessResult, error) {
	if p.Aggregator == nil {
		return ProcessResult{}, poker.ErrInvalidInput("aggregator is required")
	}
	base, err := msg.SimulationRequest()
	if err != nil {
		return ProcessResult{}, err
	}
	result, err := poker.SimulateChunk(base, msg.Chunk())
	if err != nil {
		return ProcessResult{}, err
	}
	applied, snapshot, err := p.Aggregator.ApplyChunkResult(ctx, NewAggregateDelta(msg, result))
	if err != nil {
		return ProcessResult{}, err
	}
	return ProcessResult{
		Message: msg,
		Poker:   result,
		Applied: applied,
		State:   snapshot,
	}, nil
}
