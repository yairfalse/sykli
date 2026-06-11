package main

import sykli "github.com/false-systems/sykli/sdk/go"

func main() {
	p := sykli.New()
	p.Task("test").
		Run("go test ./...").
		TaskType(sykli.TaskTypeTest).
		EvidenceRequired(sykli.FileEvidenceNonEmpty("coverage", "coverage.out"))
	p.Emit()
}
