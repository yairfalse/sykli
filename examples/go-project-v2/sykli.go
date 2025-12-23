//go:build ignore

// Example: Go project using SDK composition features
//
// This example demonstrates:
// - Templates for DRY container configuration
// - Parallel groups for concurrent tasks
// - Chain for sequential pipelines

package main

import sykli "sykli.dev/go"

func main() {
	s := sykli.New()

	// === RESOURCES ===
	src := s.Dir(".")
	goModCache := s.Cache("go-mod")
	goBuildCache := s.Cache("go-build")

	// === TEMPLATE ===
	// Define once, use everywhere - no more copy-paste!
	golang := s.Template("golang").
		Container("golang:1.21").
		Mount(src, "/src").
		MountCache(goModCache, "/go/pkg/mod").
		MountCache(goBuildCache, "/root/.cache/go-build").
		Workdir("/src")

	// === TASKS ===
	// Each task inherits from the template - much cleaner!

	// Parallel checks - run concurrently
	checks := s.Parallel("checks",
		s.Task("lint").From(golang).Run("go vet ./..."),
		s.Task("fmt").From(golang).Run("gofmt -l ."),
		s.Task("test").From(golang).Run("go test ./..."),
	)

	// Build depends on all checks passing
	build := s.Task("build").
		From(golang).
		Env("CGO_ENABLED", "0").
		Run("go build -o ./app .").
		Output("binary", "./app").
		AfterGroup(checks)

	// Deploy only on main branch
	s.Task("deploy").
		Run("./deploy.sh").
		When("branch == 'main'").
		After(build.Name())

	s.Emit()
}
