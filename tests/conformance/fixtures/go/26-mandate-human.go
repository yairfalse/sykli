package main

import sykli "github.com/false-systems/sykli/sdk/go"

func main() {
	p := sykli.New()
	p.Task("docs").
		Run("make docs").
		Actor(sykli.ActorKindHuman, "maintainer").
		Mandate(sykli.NewMandate(
			[]string{"docs/**", "README.md"},
			sykli.DiffLines(200),
			sykli.WallClockMS(900000),
			sykli.Network(false),
		))
	p.Emit()
}
