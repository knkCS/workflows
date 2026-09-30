// Package gomodule is a self-test fixture: the smallest Go module that
// go-service-ci's `go` job can vet and test from a `working-directory`, so
// self-test.yml can prove the Go job end to end in this repo. It has no
// dependencies, so it has no go.sum.
package gomodule

// Areas lists the change areas, in the order the classifier prints them.
func Areas() []string { return []string{"docs", "go", "ui", "image"} }
