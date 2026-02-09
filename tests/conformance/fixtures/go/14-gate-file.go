package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
	p := sykli.New()

	p.Gate("wait-approval").
		GateStrategy("file").
		GateTimeout(1800).
		GateFilePath("/tmp/approved")

	p.Emit()
}
