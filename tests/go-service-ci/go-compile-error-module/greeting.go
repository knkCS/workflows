// Package gocompileerrormodule is a self-test fixture that does NOT compile,
// on purpose: two changes that were each fine alone — one renamed Greet to
// Greeting, the other added a caller of Greet — merged together.
// go-service-ci's merge check must fail on it.
package gocompileerrormodule

// Greeting was Greet before one of the two changes renamed it.
func Greeting() string { return "hello" }
