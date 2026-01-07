//go:build ignore

// sykli.go - CI pipeline for Sykli itself (dogfooding!)
//
// Run with: sykli
package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
	s := sykli.New()

	// === CORE (Elixir) ===
	s.Task("core:deps").Run("cd core && mix deps.get")
	s.Task("core:test").Run("cd core && mix test").After("core:deps")

	// === GO SDK ===
	s.Task("go:test").Run("cd sdk/go && go test ./...")
	s.Task("go:vet").Run("cd sdk/go && go vet ./...")

	// === RUST SDK ===
	s.Task("rust:test").Run("cd sdk/rust && cargo test")
	s.Task("rust:fmt").Run("cd sdk/rust && cargo fmt --check")

	// === ELIXIR SDK ===
	s.Task("elixir:deps").Run("cd sdk/elixir && mix deps.get")
	s.Task("elixir:test").Run("cd sdk/elixir && mix test").After("elixir:deps")

	// === ALL TESTS ===
	s.Task("all").
		Run("echo 'All tests passed!'").
		After("core:test", "go:test", "go:vet", "rust:test", "rust:fmt", "elixir:test")

	s.Emit()
}
