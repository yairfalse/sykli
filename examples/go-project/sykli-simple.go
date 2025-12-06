//go:build ignore

// Simple example using v1 API (no containers)
package main

import sykli "sykli.dev/go"

func main() {
	s := sykli.New()

	// Use Go presets - simple and clean
	s.Go().Test()
	s.Go().Lint()
	s.Go().Build("./app").After("test", "lint")

	s.Emit()
}
