package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
	p := sykli.New()

	p.Task("hello").Run("echo hello")

	p.Emit()
}
