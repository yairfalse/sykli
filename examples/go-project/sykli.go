//go:build ignore

package main

import "sykli.dev/go"

func main() {
	sykli.Test()
	sykli.Lint()

	// Build depends on test and lint passing
	sykli.Build("./app")
	sykli.After("test")
	sykli.After("lint")

	sykli.MustEmit()
}
