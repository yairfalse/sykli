//go:build ignore

package main

import (
	"encoding/json"
	"os"
)

type Task struct {
	Name      string   `json:"name"`
	Command   string   `json:"command"`
	Inputs    []string `json:"inputs,omitempty"`
	DependsOn []string `json:"depends_on,omitempty"`
}

var tasks []Task

func task(name, cmd string, deps ...string) {
	tasks = append(tasks, Task{
		Name:      name,
		Command:   cmd,
		DependsOn: deps,
		Inputs:    []string{"**/*.go", "go.mod"},
	})
}

func main() {
	task("test", "go test ./...")
	task("lint", "go vet ./...")
	task("build", "go build -o ./app", "test", "lint")

	for _, arg := range os.Args[1:] {
		if arg == "--emit" {
			json.NewEncoder(os.Stdout).Encode(map[string]any{"tasks": tasks})
			return
		}
	}
}
