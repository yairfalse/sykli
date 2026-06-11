package main

import sykli "github.com/false-systems/sykli/sdk/go"

func main() {
	p := sykli.New()

	p.Task("A").Run("echo A").After("B")
	p.Task("B").Run("echo B").After("A")

	p.Emit()
}
