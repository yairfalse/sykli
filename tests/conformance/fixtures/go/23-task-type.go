package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
	p := sykli.New()

	p.Task("build").Run("go build ./...").TaskType(sykli.TaskTypeBuild)
	p.Task("test").Run("go test ./...").TaskType(sykli.TaskTypeTest).After("build")

	p.Emit()
}
