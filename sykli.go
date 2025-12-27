//go:build ignore

// Sykli CI for Sykli itself - dogfooding!
//
// Run locally:  sykli
// Run in CI:    sykli (via GitHub Actions)

package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
	s := sykli.New()

	// === CORE TESTS ===
	s.Task("core:deps").
		Run("mix deps.get").
		Workdir("core")

	s.Task("core:test").
		Run("mix test").
		Workdir("core").
		After("core:deps")

	s.Task("core:build").
		Run("mix escript.build").
		Workdir("core").
		After("core:test")

	// === SDK TESTS (parallel) ===
	s.Task("sdk:go").
		Run("go test ./...").
		Workdir("sdk/go")

	s.Task("sdk:rust").
		Run("cargo test").
		Workdir("sdk/rust")

	s.Task("sdk:elixir:deps").
		Run("mix deps.get").
		Workdir("sdk/elixir")

	s.Task("sdk:elixir").
		Run("mix test").
		Workdir("sdk/elixir").
		After("sdk:elixir:deps")

	// === INTEGRATION (after everything) ===
	s.Task("integration").
		Run("./sykli ../examples/go-project").
		Workdir("core").
		After("core:build", "sdk:go")

	s.Emit()
}
