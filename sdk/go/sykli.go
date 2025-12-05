// Package sykli provides a fluent API for defining CI pipelines.
//
// Example:
//
//	s := sykli.New()
//	s.Task("test").Run("go test ./...").Inputs("**/*.go", "go.mod")
//	s.Task("build").Run("go build -o app").After("test")
//	s.Emit()
package sykli

import (
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"time"
)

type Task struct {
	Name      string   `json:"name"`
	Command   string   `json:"command"`
	Inputs    []string `json:"inputs,omitempty"`
	Outputs   []string `json:"outputs,omitempty"`
	DependsOn []string `json:"depends_on,omitempty"`
}

const (
	Stop     FailureMode = "stop"
	Continue FailureMode = "continue"
)

// Retry returns a failure mode that retries N times
func Retry(n int) FailureMode {
	return FailureMode("retry:" + strconv.Itoa(n))
}

// Pipeline represents a CI pipeline
type Pipeline struct {
	tasks      []*Task
	requiredEnv []string
	github     *GitHubConfig
}

// Task represents a single task in the pipeline
type Task struct {
	name      string
	command   string
	inputs    []string
	outputs   []string
	dependsOn []string
	timeout   time.Duration
	onFailure FailureMode
}

// GitHubConfig holds GitHub integration settings
type GitHubConfig struct {
	enabled       bool
	perTaskStatus bool
	contextPrefix string
}

// New creates a new pipeline
func New() *Pipeline {
	return &Pipeline{
		tasks:  make([]*Task, 0),
		github: &GitHubConfig{contextPrefix: "ci/sykli"},
	}
}

// Task creates a new task with the given name
func (p *Pipeline) Task(name string) *Task {
	if name == "" {
		panic("task name cannot be empty")
	}
	for _, existing := range p.tasks {
		if existing.name == name {
			panic(fmt.Sprintf("task %q already exists", name))
		}
	}
	t := &Task{
		name:      name,
		timeout:   5 * time.Minute,
		onFailure: Stop,
	}
	p.tasks = append(p.tasks, t)
	return t
}

// RequireEnv declares required environment variables
func (p *Pipeline) RequireEnv(vars ...string) *Pipeline {
	p.requiredEnv = append(p.requiredEnv, vars...)
	return p
}

// GitHub returns the GitHub configuration
func (p *Pipeline) GitHub() *GitHubConfig {
	p.github.enabled = true
	return p.github
}

// Outputs sets output paths for caching
func (b *TaskBuilder) Outputs(paths ...string) *TaskBuilder {
	b.task.Outputs = append(b.task.Outputs, paths...)
	return b
}

// Run adds an arbitrary command as a task
func Run(cmd string) {
	task := Task{
		Name:    cmd,
		Command: cmd,
	}
	return g
}

// Run sets the command for this task
func (t *Task) Run(cmd string) *Task {
	t.command = cmd
	return t
}

// After sets dependencies for this task
func (t *Task) After(tasks ...string) *Task {
	t.dependsOn = append(t.dependsOn, tasks...)
	return t
}

// Build adds a build task
func Build(output string) {
	task := Task{
		Name:    "build",
		Command: "go build -o " + output,
		Inputs:  []string{"**/*.go", "go.mod", "go.sum"},
		Outputs: []string{output},
	}
	if lastTask != "" {
		task.DependsOn = []string{lastTask}
	}
	current.Tasks = append(current.Tasks, task)
	lastTask = "build"
}

// Outputs sets output paths (artifacts)
func (t *Task) Outputs(paths ...string) *Task {
	t.outputs = append(t.outputs, paths...)
	return t
}

// Timeout sets the task timeout
func (t *Task) Timeout(d time.Duration) *Task {
	if d <= 0 {
		panic("timeout must be positive")
	}
	t.timeout = d
	return t
}

// OnFailure sets the failure handling mode
func (t *Task) OnFailure(mode FailureMode) *Task {
	t.onFailure = mode
	return t
}

// Emit outputs the pipeline as JSON if --emit flag is present
func (p *Pipeline) Emit() {
	for _, arg := range os.Args[1:] {
		if arg == "--emit" {
			p.emit()
			os.Exit(0)
		}
	}
}

// MustEmit is an alias for Emit
func (p *Pipeline) MustEmit() {
	p.Emit()
}

func (p *Pipeline) emit() {
	// Validate all tasks
	taskNames := make(map[string]bool)
	for _, t := range p.tasks {
		taskNames[t.name] = true
	}
	for _, t := range p.tasks {
		if t.command == "" {
			fmt.Fprintf(os.Stderr, "error: task %q has no command\n", t.name)
			os.Exit(1)
		}
		for _, dep := range t.dependsOn {
			if !taskNames[dep] {
				fmt.Fprintf(os.Stderr, "error: task %q depends on unknown task %q\n", t.name, dep)
				os.Exit(1)
			}
		}
	}

	type jsonTask struct {
		Name      string   `json:"name"`
		Command   string   `json:"command"`
		Inputs    []string `json:"inputs,omitempty"`
		Outputs   []string `json:"outputs,omitempty"`
		DependsOn []string `json:"depends_on,omitempty"`
		Timeout   int      `json:"timeout,omitempty"`
		OnFailure string   `json:"on_failure,omitempty"`
	}

	type jsonGitHub struct {
		Enabled       bool   `json:"enabled"`
		PerTaskStatus bool   `json:"per_task_status"`
		ContextPrefix string `json:"context_prefix"`
	}

	type jsonPipeline struct {
		Version     string      `json:"version"`
		RequiredEnv []string    `json:"required_env,omitempty"`
		GitHub      *jsonGitHub `json:"github,omitempty"`
		Tasks       []jsonTask  `json:"tasks"`
	}

	tasks := make([]jsonTask, len(p.tasks))
	for i, t := range p.tasks {
		tasks[i] = jsonTask{
			Name:      t.name,
			Command:   t.command,
			Inputs:    t.inputs,
			Outputs:   t.outputs,
			DependsOn: t.dependsOn,
			Timeout:   int(t.timeout.Seconds()),
			OnFailure: string(t.onFailure),
		}
	}

	out := jsonPipeline{
		Version:     "1",
		RequiredEnv: p.requiredEnv,
		Tasks:       tasks,
	}

	if p.github.enabled {
		out.GitHub = &jsonGitHub{
			Enabled:       true,
			PerTaskStatus: p.github.perTaskStatus,
			ContextPrefix: p.github.contextPrefix,
		}
	}

	if err := json.NewEncoder(os.Stdout).Encode(out); err != nil {
		fmt.Fprintf(os.Stderr, "error encoding pipeline: %v\n", err)
		os.Exit(1)
	}
}
