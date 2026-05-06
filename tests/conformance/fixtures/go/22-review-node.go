package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
	p := sykli.New()

	p.Task("test").Run("go test ./...")
	p.Review("review-code").
		Primitive("lint").
		Agent("claude").
		Context("src/**/*.go").
		After("test").
		Deterministic(true)

	p.Emit()
}
