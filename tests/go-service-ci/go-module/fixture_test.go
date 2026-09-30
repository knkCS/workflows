package gomodule

import "testing"

func TestAreas(t *testing.T) {
	if got := len(Areas()); got != 4 {
		t.Fatalf("want 4 change areas, got %d", got)
	}
}
