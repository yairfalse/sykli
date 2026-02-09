package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
	p := sykli.New()

	p.Task("A").Run("echo A")
	p.Task("B").Run("echo B").After("A")
	p.Task("C").Run("echo C").After("B")
	p.Task("D").Run("echo D").After("C")
	p.Task("E").Run("echo E").After("D")

	p.Emit()
}
