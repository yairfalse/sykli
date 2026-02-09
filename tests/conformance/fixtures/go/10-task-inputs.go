package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
	p := sykli.New()

	p.Task("build").Run("go build -o /out/app").
		Output("binary", "/out/app")

	p.Task("test").Run("./app test").
		InputFrom("build", "binary", "/app")

	p.Emit()
}
