package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
	p := sykli.New()

	// Empty env key should fail
	p.Task("test").Run("echo test").Env("", "value")

	p.Emit()
}
