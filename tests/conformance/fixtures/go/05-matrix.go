package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
	p := sykli.New()

	p.Task("test").Run("go test ./...").
		Matrix("os", "linux", "darwin").
		Matrix("arch", "amd64", "arm64")

	p.Emit()
}
