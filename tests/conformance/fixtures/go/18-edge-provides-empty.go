package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
	p := sykli.New()

	// provides with empty string value should omit value field
	p.Task("build").Run("make build").Provides("artifact", "")

	// provides with no value should also omit value field
	p.Task("migrate").Run("dbmate up").Provides("db-ready")

	// provides with actual value should include it
	p.Task("package").Run("docker build").Provides("image", "myapp:latest").After("build")

	p.Emit()
}
