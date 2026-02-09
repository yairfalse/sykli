package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
	p := sykli.New()

	p.Task("test").Run("go test ./...").After("nonexistent")

	p.Emit()
}
