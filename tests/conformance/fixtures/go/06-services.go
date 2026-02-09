package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
	p := sykli.New()

	p.Task("test").Run("pytest").
		Service("postgres:15", "db").
		Service("redis:7", "cache")

	p.Emit()
}
