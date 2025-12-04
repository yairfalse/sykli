package sykli

import (
	"encoding/json"
	"os"
	"path/filepath"
)

type Task struct {
	Name      string   `json:"name"`
	Command   string   `json:"command"`
	Inputs    []string `json:"inputs,omitempty"`
	DependsOn []string `json:"depends_on,omitempty"`
}

type graph struct {
	Tasks []Task `json:"tasks"`
}

var current graph
var lastTask string

// TaskBuilder allows fluent task configuration
type TaskBuilder struct {
	task *Task
}

// Task creates a new task with the given name
func NewTask(name string) *TaskBuilder {
	t := &Task{Name: name}
	current.Tasks = append(current.Tasks, *t)
	lastTask = name
	return &TaskBuilder{task: &current.Tasks[len(current.Tasks)-1]}
}

// Run sets the command for this task
func (b *TaskBuilder) Run(cmd string) *TaskBuilder {
	b.task.Command = cmd
	return b
}

// After sets dependencies for this task
func (b *TaskBuilder) DependsOn(tasks ...string) *TaskBuilder {
	b.task.DependsOn = append(b.task.DependsOn, tasks...)
	return b
}

// Inputs sets input globs for caching
func (b *TaskBuilder) Inputs(patterns ...string) *TaskBuilder {
	b.task.Inputs = append(b.task.Inputs, patterns...)
	return b
}

// Run adds an arbitrary command as a task
func Run(cmd string) {
	task := Task{
		Name:    cmd,
		Command: cmd,
	}
	if lastTask != "" {
		task.DependsOn = []string{lastTask}
	}
	current.Tasks = append(current.Tasks, task)
	lastTask = cmd
}

// Test adds a test task (auto-detects Go)
func Test() {
	task := Task{
		Name:    "test",
		Command: "go test ./...",
		Inputs:  []string{"**/*.go", "go.mod", "go.sum"},
	}
	current.Tasks = append(current.Tasks, task)
	lastTask = "test"
}

// Lint adds a lint task
func Lint() {
	task := Task{
		Name:    "lint",
		Command: "go vet ./...",
		Inputs:  []string{"**/*.go"},
	}
	current.Tasks = append(current.Tasks, task)
	lastTask = "lint"
}

// Build adds a build task
func Build(output string) {
	task := Task{
		Name:    "build",
		Command: "go build -o " + output,
		Inputs:  []string{"**/*.go", "go.mod", "go.sum"},
	}
	if lastTask != "" {
		task.DependsOn = []string{lastTask}
	}
	current.Tasks = append(current.Tasks, task)
	lastTask = "build"
}

// Check runs all standard checks (test + lint)
func Check() {
	Test()
	Lint()
}

// After sets dependency on a previous task
func After(taskName string) {
	if len(current.Tasks) > 0 {
		last := &current.Tasks[len(current.Tasks)-1]
		last.DependsOn = append(last.DependsOn, taskName)
	}
}

// Emit outputs the task graph as JSON (called when --emit flag is present)
func Emit() {
	for _, arg := range os.Args[1:] {
		if arg == "--emit" {
			json.NewEncoder(os.Stdout).Encode(current)
			os.Exit(0)
		}
	}
}

// MustEmit is like Emit but should be called at the end of main()
// It checks for --emit and outputs JSON, otherwise does nothing
func MustEmit() {
	Emit()
}

// Detect checks if this is a Go project
func Detect() bool {
	_, err := os.Stat("go.mod")
	return err == nil
}

// FindInputs returns glob patterns for Go files
func FindInputs() []string {
	return []string{"**/*.go", "go.mod", "go.sum"}
}

// Init sets up the working directory
func Init() {
	if wd := os.Getenv("SYKLI_WORKDIR"); wd != "" {
		os.Chdir(wd)
	}
}

// helper to find project root
func findProjectRoot() string {
	dir, _ := os.Getwd()
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	return ""
}
