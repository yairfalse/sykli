package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
	p := sykli.New()
	p.Task("test").
		Run("go test ./...").
		TaskType(sykli.TaskTypeTest).
		SuccessCriteria(
			sykli.ExitCode(0),
			sykli.FileExists("coverage.out"),
		)
	p.Task("package").
		Run("go build -o dist/app ./...").
		TaskType(sykli.TaskTypePackage).
		SuccessCriteria(sykli.FileNonEmpty("dist/app")).
		After("test")
	p.Emit()
}
