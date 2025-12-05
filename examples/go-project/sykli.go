//go:build ignore

package main

import sykli "sykli.dev/go"

func main() {
	s := sykli.New()

	s.Task("test").Run("go test ./...").Inputs("**/*.go", "go.mod")
	s.Task("lint").Run("go vet ./...").Inputs("**/*.go")
	s.Task("build").Run("go build -o ./app").After("test", "lint")

	s.Emit()
}
