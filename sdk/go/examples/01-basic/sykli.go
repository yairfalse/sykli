//go:build ignore

// Example 01: Basic Pipeline
//
// This example demonstrates:
// - Creating tasks with Run()
// - Defining dependencies with After()
// - Parallel execution of independent tasks
//
// Run with: sykli run

package main

import sykli "sykli.dev/go"

func main() {
	s := sykli.New()

	// Independent tasks run in parallel
	s.Task("lint").Run("go vet ./...")
	s.Task("test").Run("go test ./...")

	// Build depends on both lint and test
	// It won't start until both complete successfully
	s.Task("build").
		Run("go build -o ./app").
		After("lint", "test")

	// Deploy depends on build
	// Only runs after build completes
	s.Task("deploy").
		Run("echo 'Deploying...'").
		After("build")

	s.Emit()
}

// Expected execution order:
//
// Level 0 (parallel):  lint, test
// Level 1:             build
// Level 2:             deploy
//
// Total: 4 tasks in 3 levels
