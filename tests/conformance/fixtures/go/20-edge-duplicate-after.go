package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
	p := sykli.New()

	p.Task("build").Run("make build")

	// Duplicate after calls should be deduplicated
	p.Task("test").Run("go test").After("build").After("build")

	p.Task("deploy").Run("./deploy.sh").After("build", "test", "build", "test")

	p.Emit()
}
