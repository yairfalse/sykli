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
	Outputs   []string `json:"outputs,omitempty"`
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

func taskWithOutputs(name, cmd string, outputs []string, deps ...string) {
	tasks = append(tasks, Task{
		Name:      name,
		Command:   cmd,
		DependsOn: deps,
		Inputs:    []string{"**/*.go", "go.mod"},
		Outputs:   outputs,
	})
}

func main() {
	task("test", "go test ./...")
	task("lint", "go vet ./...")
	taskWithOutputs("build", "go build -o ./app", []string{"./app"}, "test", "lint")

	s.Emit()
}
