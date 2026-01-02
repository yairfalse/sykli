//go:build ignore

// Example 04: Templates
//
// This example demonstrates:
// - Template() for reusable configurations
// - From() to inherit template settings
// - Override template settings per-task
//
// Templates eliminate repetition. Define container, mounts,
// and environment once, reuse across many tasks.
//
// Run with: sykli run

package main

import sykli "sykli.dev/go"

func main() {
	s := sykli.New()

	// === RESOURCES ===
	src := s.Dir(".")
	goModCache := s.Cache("go-mod")
	goBuildCache := s.Cache("go-build")

	// === TEMPLATES ===

	// Go template - common config for all Go tasks
	golang := s.Template("golang").
		Container("golang:1.21").
		Mount(src, "/src").
		MountCache(goModCache, "/go/pkg/mod").
		MountCache(goBuildCache, "/root/.cache/go-build").
		Workdir("/src").
		Env("GOFLAGS", "-mod=readonly")

	// Node template - for JS tooling
	node := s.Template("node").
		Container("node:20-slim").
		Mount(src, "/src").
		MountCache(s.Cache("npm"), "/root/.npm").
		Workdir("/src")

	// === TASKS ===

	// All Go tasks inherit from the golang template
	// Only task-specific config needed now!
	s.Task("lint").From(golang).Run("go vet ./...")
	s.Task("test").From(golang).Run("go test ./...")

	// Override template settings when needed
	s.Task("build").
		From(golang).
		Env("CGO_ENABLED", "0").  // Overrides/adds to template env
		Run("go build -o ./app").
		Output("binary", "./app").
		After("lint", "test")

	// Different template for JS tasks
	s.Task("docs").
		From(node).
		Run("npm run build:docs")

	s.Emit()
}

// Without templates (repetitive):
//   s.Task("lint").Container("golang:1.21").Mount(src, "/src")...
//   s.Task("test").Container("golang:1.21").Mount(src, "/src")...
//   s.Task("build").Container("golang:1.21").Mount(src, "/src")...
//
// With templates (DRY):
//   golang := s.Template("golang").Container("golang:1.21").Mount(src, "/src")...
//   s.Task("lint").From(golang).Run("go vet")
//   s.Task("test").From(golang).Run("go test")
//   s.Task("build").From(golang).Run("go build")
