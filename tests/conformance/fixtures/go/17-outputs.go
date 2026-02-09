package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
	p := sykli.New()

	p.Task("build").Run("make build").
		Output("binary", "/out/app").
		Output("checksum", "/out/sha256")

	p.Emit()
}
