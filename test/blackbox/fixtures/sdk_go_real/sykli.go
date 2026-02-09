//go:build ignore

package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
	s := sykli.New()

	s.Task("lint").Run("echo lint ok")
	s.Task("test").Run("echo test ok")
	s.Task("build").Run("echo build ok").After("lint", "test")

	s.Emit()
}
