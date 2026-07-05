package main

import sykli "github.com/false-systems/sykli/sdk/go"

func main() {
	p := sykli.New()
	p.Task("implement").
		Run("go test ./...").
		TaskType(sykli.TaskTypeTest).
		SuccessCriteria(sykli.ExitCode(0)).
		EvidenceRequired(sykli.FileEvidenceNonEmpty("coverage", "coverage.out")).
		Actor(sykli.ActorKindAgent, "claude").
		Mandate(sykli.NewMandate([]string{"sdk/**", "tests/conformance/**"}))
	p.Emit()
}
