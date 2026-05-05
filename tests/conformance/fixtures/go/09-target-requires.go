package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
	p := sykli.New()

	p.Task("build").Run("make build").
		Requires("gpu", "high-memory")

	p.Emit()
}
