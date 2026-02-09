package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
	p := sykli.New()

	p.Task("test").Run("npm test").
		Container("node:20").
		Workdir("/app").
		Env("NODE_ENV", "test").
		Env("CI", "true").
		Retry(3).
		Timeout(300).
		Secrets("NPM_TOKEN", "GH_TOKEN").
		When("branch:main")

	p.Emit()
}
