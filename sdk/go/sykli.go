// Package sykli provides a fluent API for defining CI pipelines.
//
// Example:
//
//	s := sykli.New()
//	s.Task("test").Run("go test ./...").Inputs("**/*.go")
//	s.Task("build").Run("go build -o app").After("test")
//	s.Emit()
package sykli

import (
	"encoding/json"
	"os"
	"time"
)

// FailureMode defines how to handle task failures
type FailureMode string

const (
	Stop     FailureMode = "stop"
	Continue FailureMode = "continue"
)

// Retry returns a failure mode that retries N times
func Retry(n int) FailureMode {
	return FailureMode("retry:" + string(rune('0'+n)))
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

// PerTaskStatus enables per-task commit status
func (g *GitHubConfig) PerTaskStatus(prefix ...string) *GitHubConfig {
	g.perTaskStatus = true
	if len(prefix) > 0 {
		g.contextPrefix = prefix[0]
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

// Inputs sets input globs for caching
func (t *Task) Inputs(patterns ...string) *Task {
	t.inputs = append(t.inputs, patterns...)
	return t
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

	json.NewEncoder(os.Stdout).Encode(out)
}
