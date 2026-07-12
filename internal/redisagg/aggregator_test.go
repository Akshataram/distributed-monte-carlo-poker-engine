package redisagg

import "testing"

func TestRedisSlotTagKeyShape(t *testing.T) {
	tag := redisSlotTag("hand-123", 3)
	processed := "processed:" + tag + ":7"
	aggregate := "aggregate:" + tag

	if tag != "{hand-123:3}" {
		t.Fatalf("slot tag=%q", tag)
	}
	if processed != "processed:{hand-123:3}:7" {
		t.Fatalf("processed key=%q", processed)
	}
	if aggregate != "aggregate:{hand-123:3}" {
		t.Fatalf("aggregate key=%q", aggregate)
	}
}
