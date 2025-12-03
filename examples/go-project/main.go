package main

import "fmt"

func main() {
	fmt.Println(Greet("world"))
}

func Greet(name string) string {
	return "Hello, " + name + "!"
}
