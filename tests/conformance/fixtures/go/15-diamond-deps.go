package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
	p := sykli.New()

	p.Task("A").Run("echo A")
	p.Task("B").Run("echo B").After("A")
	p.Task("C").Run("echo C").After("A")
	p.Task("D").Run("echo D").After("B", "C")

	p.Emit()
}
