package poker

import "testing"

func TestEvaluateCategories(t *testing.T) {
	tests := []struct {
		name     string
		cards    string
		category int
	}{
		{"royal-ish straight flush", "As Ks Qs Js Ts 2d 3c", StraightFlush},
		{"quads", "As Ah Ac Ad Ks 2c 3d", Quads},
		{"full house", "As Ah Ac Ks Kd 2c 3d", FullHouse},
		{"flush", "As Qs 9s 6s 2s Kd 3c", Flush},
		{"wheel straight", "As 2d 3h 4c 5s Kd Qc", Straight},
		{"trips", "As Ah Ac Ks Qd 2c 3d", Trips},
		{"two pair", "As Ah Ks Kd Qc 2c 3d", TwoPair},
		{"pair", "As Ah Ks Qd Jc 2c 3d", OnePair},
		{"high card", "As Kd Qh 9c 7s 4c 2d", HighCard},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := Evaluate(MustParseCards(tt.cards)).Category()
			if got != tt.category {
				t.Fatalf("category=%d want=%d", got, tt.category)
			}
		})
	}
}

func TestHandOrdering(t *testing.T) {
	flush := Evaluate(MustParseCards("As Qs 9s 6s 2s Kd 3c"))
	straight := Evaluate(MustParseCards("As 2d 3h 4c 5s Kd Qc"))
	if flush <= straight {
		t.Fatalf("flush should outrank straight")
	}

	aceHigh := Evaluate(MustParseCards("As Kd Qh 9c 7s 4c 2d"))
	kingHigh := Evaluate(MustParseCards("Ks Qd Jh 9c 7s 4c 2d"))
	if aceHigh <= kingHigh {
		t.Fatalf("ace high should outrank king high")
	}
}
