package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
	p := sykli.New()

	// retry(0) should be omitted from JSON (same as not setting it)
	p.Task("test").Run("echo test").Retry(0)

	// retry(2) should appear
	p.Task("flaky").Run("echo flaky").Retry(2)

	p.Emit()
}
