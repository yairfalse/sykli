//go:build ignore

// Example 05: Composition
//
// This example demonstrates:
// - Parallel() for concurrent task groups
// - Chain() for sequential pipelines
// - InputFrom() for artifact passing
// - AfterGroup() for depending on task groups
//
// These combinators make complex pipelines readable.
//
// Run with: sykli run

package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
	s := sykli.New()

	// === RESOURCES ===
	src := s.Dir(".")
	goModCache := s.Cache("go-mod")
	goBuildCache := s.Cache("go-build")

	// === TEMPLATE ===
	golang := s.Template("golang").
		Container("golang:1.21").
		Mount(src, "/src").
		MountCache(goModCache, "/go/pkg/mod").
		MountCache(goBuildCache, "/root/.cache/go-build").
		Workdir("/src")

	// === PARALLEL GROUP ===
	// All checks run concurrently
	checks := s.Parallel("checks",
		s.Task("lint").From(golang).Run("go vet ./..."),
		s.Task("fmt").From(golang).Run("gofmt -l . | tee /dev/stderr | wc -l | xargs test 0 -eq"),
		s.Task("test").From(golang).Run("go test ./..."),
		s.Task("security").From(golang).Run("go list -m all | head -20"),
	)

	// === BUILD ===
	// Depends on all checks passing
	build := s.Task("build").
		From(golang).
		Env("CGO_ENABLED", "0").
		Run("go build -o /out/app .").
		Output("binary", "/out/app").  // Named output
		AfterGroup(checks)

	// === ARTIFACT PASSING ===
	// InputFrom automatically:
	// 1. Adds dependency on "build"
	// 2. Makes the artifact available at "./app"
	s.Task("package").
		Container("docker:24").
		MountCwd().
		Run("docker build -t myapp:latest .").
		InputFrom("build", "binary", "./app")

	// === CHAIN ===
	// Alternative way to express sequential dependencies
	// Creates: integration -> e2e
	integration := s.Task("integration").
		From(golang).
		Run("go test -tags=integration ./...").
		After(build.Name())

	e2e := s.Task("e2e").
		Run("./scripts/e2e.sh")

	deploy := s.Task("deploy").
		Run("./scripts/deploy.sh").
		When("branch == 'main'")

	// Chain creates: integration -> e2e -> deploy
	s.Chain(integration, e2e, deploy)

	s.Emit()
}

// Execution flow:
//
// [lint] ─┐
// [fmt]  ─┼─> [build] ─> [package]
// [test] ─┤
// [security]┘
//           └──────────> [integration] ─> [e2e] ─> [deploy]
