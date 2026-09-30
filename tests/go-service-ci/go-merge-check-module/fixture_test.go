package gomergecheckmodule

import "testing"

// The merge check runs no tests; if this ever runs there, it goes red.
func TestMergeCheckRunsNoTests(t *testing.T) {
	t.Fatalf("the merge check must not run tests, but ran this one (mode %q)", Mode())
}
