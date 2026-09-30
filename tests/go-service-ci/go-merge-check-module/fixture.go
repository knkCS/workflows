// Package gomergecheckmodule is a self-test fixture for go-service-ci's
// merge check: a module that vets clean but whose one test always fails, so a
// green merge check proves it ran no tests.
package gomergecheckmodule

// Mode is the go-service-ci mode this fixture exists for.
func Mode() string { return "merge-check" }
