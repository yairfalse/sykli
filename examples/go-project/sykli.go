//go:build ignore

package main

import sykli "sykli.dev/go"

func main() {
	s := sykli.New()

	// === RESOURCES ===
	src := s.Dir(".")
	goModCache := s.Cache("go-mod")
	goBuildCache := s.Cache("go-build")

	// === TASKS ===

	// Lint - runs in container with caches
	s.Task("lint").
		Container("golang:1.21").
		Mount(src, "/src").
		MountCache(goModCache, "/go/pkg/mod").
		Workdir("/src").
		Run("go vet ./...")

	// Test - runs in container with caches
	s.Task("test").
		Container("golang:1.21").
		Mount(src, "/src").
		MountCache(goModCache, "/go/pkg/mod").
		MountCache(goBuildCache, "/root/.cache/go-build").
		Workdir("/src").
		Run("go test ./...")

	// Build - depends on lint and test
	s.Task("build").
		Container("golang:1.21").
		Mount(src, "/src").
		MountCache(goModCache, "/go/pkg/mod").
		MountCache(goBuildCache, "/root/.cache/go-build").
		Workdir("/src").
		Env("CGO_ENABLED", "0").
		Run("go build -o ./app .").
		Output("binary", "./app").
		After("lint", "test")

	s.Emit()
}
