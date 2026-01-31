//go:build ignore

// Example 03: Container Execution
//
// This example demonstrates:
// - Container() for isolated execution
// - Dir() and Cache() resources
// - Mount() and MountCache() for volumes
// - Workdir() for working directory
// - Env() for environment variables
//
// Run with: sykli run

package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
	s := sykli.New()

	// === RESOURCES ===

	// Source directory - mounted into containers
	src := s.Dir(".")

	// Named caches - persist across runs
	goModCache := s.Cache("go-mod")       // Go module cache
	goBuildCache := s.Cache("go-build")   // Go build cache

	// === TASKS ===

	// Lint in container with source mounted
	s.Task("lint").
		Container("golang:1.21").
		Mount(src, "/src").
		MountCache(goModCache, "/go/pkg/mod").
		Workdir("/src").
		Run("go vet ./...")

	// Test with multiple caches
	s.Task("test").
		Container("golang:1.21").
		Mount(src, "/src").
		MountCache(goModCache, "/go/pkg/mod").
		MountCache(goBuildCache, "/root/.cache/go-build").
		Workdir("/src").
		Run("go test -v ./...")

	// Build with environment variable
	s.Task("build").
		Container("golang:1.21").
		Mount(src, "/src").
		MountCache(goModCache, "/go/pkg/mod").
		MountCache(goBuildCache, "/root/.cache/go-build").
		Workdir("/src").
		Env("CGO_ENABLED", "0").
		Env("GOOS", "linux").
		Run("go build -o ./app").
		Output("binary", "./app").
		After("lint", "test")

	// === CONVENIENCE METHODS ===

	// MountCwd() is shorthand for mounting . to /work
	s.Task("check-format").
		Container("golang:1.21").
		MountCwd().  // Mounts current dir to /work, sets workdir
		Run("gofmt -l .")

	s.Emit()
}

// Key concepts:
// - Dir(".")      - Represents a host directory
// - Cache("name") - Named persistent cache volume
// - Mount(d, p)   - Mount directory at container path
// - MountCache()  - Mount cache for faster builds
// - Workdir()     - Set container working directory
