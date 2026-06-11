package main

import sykli "github.com/false-systems/sykli/sdk/go"

func main() {
	p := sykli.New()

	p.Task("test")

	p.Emit()
}
