package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
	p := sykli.New()

	p.Task("test-auth").Run("pytest tests/auth/").
		Inputs("src/auth/**/*.py", "tests/auth/**/*.py").
		Covers("src/auth/*").
		Intent("unit tests for auth module").
		SetCriticality("high").
		OnFail("analyze").
		SelectMode("smart")

	p.Emit()
}
