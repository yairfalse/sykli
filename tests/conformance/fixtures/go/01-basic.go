package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
	p := sykli.New()

	p.Task("lint").Run("npm run lint").Inputs("**/*.ts")

	p.Task("test").Run("npm test").After("lint").
		Inputs("**/*.ts", "**/*.test.ts").Timeout(120)

	p.Task("build").Run("npm run build").After("test")

	p.Emit()
}
