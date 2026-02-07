package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
	p := sykli.New()

	p.Task("compile").Run("go build -o /out/app ./cmd/server").
		Provides("binary", "/out/app")

	p.Task("migrate").Run("dbmate up").
		Provides("db-ready", "")

	p.Task("integration-test").Run("go test -tags=integration ./...").
		Needs("binary", "db-ready").Timeout(300)

	p.Emit()
}
