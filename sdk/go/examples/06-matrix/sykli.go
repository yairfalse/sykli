//go:build ignore

// Example 06: Matrix Builds & Services
//
// This example demonstrates:
// - Matrix() for testing across configurations
// - MatrixMap() for named matrix variations
// - Service() for background containers
// - Retry() and Timeout() for resilience
//
// Run with: sykli run

package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
	s := sykli.New()

	src := s.Dir(".")

	// === MATRIX BUILDS ===

	// Test across multiple Go versions
	// Creates: test-1.20, test-1.21, test-1.22
	goVersions := s.Matrix("go-test", []string{"1.20", "1.21", "1.22"}, func(version string) *sykli.Task {
		return s.Task("test-go-"+version).
			Container("golang:"+version).
			Mount(src, "/src").
			MountCache(s.Cache("go-mod-"+version), "/go/pkg/mod").
			Workdir("/src").
			Run("go test ./...")
	})

	// === NAMED MATRIX (MatrixMap) ===

	// Deploy to multiple environments
	// Creates: deploy-staging, deploy-prod
	s.MatrixMap("deploy", map[string]string{
		"staging": "staging.example.com",
		"prod":    "prod.example.com",
	}, func(env, host string) *sykli.Task {
		return s.Task("deploy-"+env).
			Run("./deploy.sh --host " + host).
			When("branch == 'main'").
			AfterGroup(goVersions)
	})

	// === SERVICE CONTAINERS ===

	// Integration tests with database and cache services
	s.Task("integration").
		Container("golang:1.21").
		Mount(src, "/src").
		Workdir("/src").
		Service("postgres:15", "db").      // Accessible as hostname "db"
		Service("redis:7", "cache").       // Accessible as hostname "cache"
		Env("DATABASE_URL", "postgres://postgres:postgres@db:5432/test?sslmode=disable").
		Env("REDIS_URL", "redis://cache:6379").
		Run("go test -tags=integration ./...").
		Timeout(300).  // 5 minute timeout
		AfterGroup(goVersions)

	// === RETRY & TIMEOUT ===

	// Flaky tests with retry
	s.Task("e2e").
		Container("cypress/included:13").
		Mount(src, "/src").
		Workdir("/src").
		Run("npm run e2e").
		Retry(3).      // Retry up to 3 times
		Timeout(600).  // 10 minute timeout
		After("integration")

	// === SECRETS ===

	// Deployment with secrets
	s.Task("publish").
		Run("./publish.sh").
		Secret("NPM_TOKEN").
		SecretFrom("GITHUB_TOKEN", sykli.FromEnv("GH_TOKEN")).
		When("tag != ''").
		After("e2e")

	s.Emit()
}

// Generated tasks:
//
// test-go-1.20  ─┐
// test-go-1.21  ─┼─> integration ─> e2e ─> publish
// test-go-1.22  ─┤
//                └─> deploy-staging
//                └─> deploy-prod
