package poker

import (
	"fmt"
	"strings"
)

const (
	rankCount = 13
	suitCount = 4
	deckSize  = 52
)

var rankChars = "23456789TJQKA"
var suitChars = "cdhs"

type Card uint8

func NewCard(rank int, suit int) Card {
	return Card(suit*rankCount + (rank - 2))
}

func (c Card) Rank() int {
	return int(c%rankCount) + 2
}

func (c Card) Suit() int {
	return int(c / rankCount)
}

func (c Card) RankIndex() int {
	return int(c % rankCount)
}

func (c Card) String() string {
	return string([]byte{rankChars[c.RankIndex()], suitChars[c.Suit()]})
}

func ParseCard(s string) (Card, error) {
	s = strings.TrimSpace(s)
	if len(s) != 2 {
		return 0, fmt.Errorf("card %q must be exactly two characters, e.g. As or Td", s)
	}

	rank := strings.IndexByte(rankChars, strings.ToUpper(s[:1])[0])
	suit := strings.IndexByte(suitChars, strings.ToLower(s[1:])[0])
	if rank < 0 || suit < 0 {
		return 0, fmt.Errorf("invalid card %q", s)
	}
	return Card(suit*rankCount + rank), nil
}

func MustParseCards(input string) []Card {
	cards, err := ParseCards(input)
	if err != nil {
		panic(err)
	}
	return cards
}

func ParseCards(input string) ([]Card, error) {
	fields := strings.FieldsFunc(input, func(r rune) bool {
		return r == ',' || r == ' ' || r == '\t' || r == '\n'
	})
	cards := make([]Card, 0, len(fields))
	seen := [deckSize]bool{}

	for _, field := range fields {
		if field == "" {
			continue
		}
		card, err := ParseCard(field)
		if err != nil {
			return nil, err
		}
		if seen[card] {
			return nil, fmt.Errorf("duplicate card %s", card)
		}
		seen[card] = true
		cards = append(cards, card)
	}
	return cards, nil
}

func NewDeck() []Card {
	deck := make([]Card, 0, deckSize)
	for suit := 0; suit < suitCount; suit++ {
		for rank := 2; rank <= 14; rank++ {
			deck = append(deck, NewCard(rank, suit))
		}
	}
	return deck
}

func RemoveKnown(deck []Card, known ...[]Card) ([]Card, error) {
	removed := [deckSize]bool{}
	for _, group := range known {
		for _, card := range group {
			if removed[card] {
				return nil, fmt.Errorf("duplicate known card %s", card)
			}
			removed[card] = true
		}
	}

	out := deck[:0]
	for _, card := range deck {
		if !removed[card] {
			out = append(out, card)
		}
	}
	return out, nil
}
