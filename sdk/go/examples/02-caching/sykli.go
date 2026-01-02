//go:build ignore

// Example 02: Input-Based Caching
//
// This example demonstrates:
// - Inputs() for content-addressed caching
// - Outputs() for declaring artifacts
// - Conditional execution with When()
//
// Tasks with unchanged inputs are skipped on subsequent runs.
//
// Run with: sykli run

package main

import sykli "sykli.dev/go"

func main() {
	s := sykli.New()

	// Test task with input patterns
	// If **/*.go files haven't changed, this task is skipped
	s.Task("test").
		Run("go test ./...").
		Inputs("**/*.go", "go.mod", "go.sum")

	// Build task with inputs and outputs
	// Skipped if inputs unchanged AND output exists
	s.Task("build").
		Run("go build -o ./app").
		Inputs("**/*.go", "go.mod", "go.sum").
		Output("binary", "./app").
		After("test")

	// Deploy only runs on main branch
	// Condition is evaluated at runtime
	s.Task("deploy").
		Run("./deploy.sh").
		When("branch == 'main'").
		After("build")

	// Type-safe alternative to When()
	// Caught at compile time, not runtime
	s.Task("release").
		Run("./release.sh").
		WhenCond(sykli.Branch("main").Or(sykli.Tag("v*"))).
		After("build")

	s.Emit()
}

// First run:  All tasks execute (no cache)
// Second run: Tasks with unchanged inputs are skipped
// Third run:  Only changed files trigger re-execution
