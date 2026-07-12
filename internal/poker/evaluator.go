package poker

import "math/bits"

type HandValue uint32

const (
	HighCard = iota
	OnePair
	TwoPair
	Trips
	Straight
	Flush
	FullHouse
	Quads
	StraightFlush
)

func (v HandValue) Category() int {
	return int(v >> 20)
}

func Evaluate(cards []Card) HandValue {
	if len(cards) < 5 || len(cards) > 7 {
		panic("Evaluate requires 5 to 7 cards")
	}

	var rankCounts [rankCount]int
	var suitMasks [suitCount]uint16
	var rankMask uint16

	for _, c := range cards {
		ri := c.RankIndex()
		bit := uint16(1 << ri)
		rankCounts[ri]++
		rankMask |= bit
		suitMasks[c.Suit()] |= bit
	}

	for _, mask := range suitMasks {
		if bits.OnesCount16(mask) >= 5 {
			if high := straightHigh(mask); high > 0 {
				return encode(StraightFlush, high)
			}
		}
	}

	quad := -1
	trips := make([]int, 0, 2)
	pairs := make([]int, 0, 3)
	singles := make([]int, 0, 7)

	for ri := rankCount - 1; ri >= 0; ri-- {
		switch rankCounts[ri] {
		case 4:
			quad = ri
		case 3:
			trips = append(trips, ri)
		case 2:
			pairs = append(pairs, ri)
		case 1:
			singles = append(singles, ri)
		}
	}

	if quad >= 0 {
		return encode(Quads, rankFromIndex(quad), firstRankNot(singles, pairs, trips, quad))
	}

	if len(trips) > 0 && (len(pairs) > 0 || len(trips) > 1) {
		pairRank := 0
		if len(trips) > 1 {
			pairRank = rankFromIndex(trips[1])
		}
		if len(pairs) > 0 && rankFromIndex(pairs[0]) > pairRank {
			pairRank = rankFromIndex(pairs[0])
		}
		return encode(FullHouse, rankFromIndex(trips[0]), pairRank)
	}

	for _, mask := range suitMasks {
		if bits.OnesCount16(mask) >= 5 {
			return encodeRanks(Flush, topRanks(mask, 5))
		}
	}

	if high := straightHigh(rankMask); high > 0 {
		return encode(Straight, high)
	}

	if len(trips) > 0 {
		kickers := topRanksExcluding(rankMask, 2, trips[0])
		return encode(Trips, rankFromIndex(trips[0]), kickers[0], kickers[1])
	}

	if len(pairs) >= 2 {
		kicker := topRanksExcluding(rankMask, 1, pairs[0], pairs[1])[0]
		return encode(TwoPair, rankFromIndex(pairs[0]), rankFromIndex(pairs[1]), kicker)
	}

	if len(pairs) == 1 {
		kickers := topRanksExcluding(rankMask, 3, pairs[0])
		return encode(OnePair, rankFromIndex(pairs[0]), kickers[0], kickers[1], kickers[2])
	}

	return encodeRanks(HighCard, topRanks(rankMask, 5))
}

func encode(category int, ranks ...int) HandValue {
	var v uint32 = uint32(category) << 20
	for i, rank := range ranks {
		shift := 16 - (i * 4)
		v |= uint32(rank) << shift
	}
	return HandValue(v)
}

func encodeRanks(category int, ranks []int) HandValue {
	return encode(category, ranks...)
}

func straightHigh(mask uint16) int {
	// Wheel: A-2-3-4-5. Ace is index 12, five is index 3.
	if mask&(1<<12) != 0 && mask&0b1111 == 0b1111 {
		return 5
	}
	for high := 12; high >= 4; high-- {
		window := uint16(0b11111) << (high - 4)
		if mask&window == window {
			return rankFromIndex(high)
		}
	}
	return 0
}

func topRanks(mask uint16, n int) []int {
	out := make([]int, 0, n)
	for ri := rankCount - 1; ri >= 0 && len(out) < n; ri-- {
		if mask&(1<<ri) != 0 {
			out = append(out, rankFromIndex(ri))
		}
	}
	return out
}

func topRanksExcluding(mask uint16, n int, exclude ...int) []int {
	var excluded [rankCount]bool
	for _, ri := range exclude {
		excluded[ri] = true
	}
	out := make([]int, 0, n)
	for ri := rankCount - 1; ri >= 0 && len(out) < n; ri-- {
		if !excluded[ri] && mask&(1<<ri) != 0 {
			out = append(out, rankFromIndex(ri))
		}
	}
	return out
}

func firstRankNot(groups ...any) int {
	exclude := -1
	if len(groups) > 0 {
		if v, ok := groups[len(groups)-1].(int); ok {
			exclude = v
			groups = groups[:len(groups)-1]
		}
	}
	for _, group := range groups {
		for _, ri := range group.([]int) {
			if ri != exclude {
				return rankFromIndex(ri)
			}
		}
	}
	return 0
}

func rankFromIndex(ri int) int {
	return ri + 2
}
