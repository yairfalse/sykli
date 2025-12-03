package main

import "testing"

func TestGreet(t *testing.T) {
	got := Greet("KULKU")
	want := "Hello, KULKU!"
	if got != want {
		t.Errorf("Greet() = %q, want %q", got, want)
	}
}
