package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
	p := sykli.New()

	// v1-style outputs (positional, auto-named)
	p.Task("build").Run("make build").Outputs("dist/app", "dist/lib")

	p.Emit()
}
