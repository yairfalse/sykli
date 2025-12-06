// Package sykli provides a fluent API for defining CI pipelines.
//
// Simple usage:
//
//	s := sykli.New()
//	s.Task("test").Run("go test ./...")
//	s.Task("build").Run("go build -o app").After("test")
//	s.Emit()
//
// With containers and caching (v2):
//
//	s := sykli.New()
//	src := s.Dir(".")
//	cache := s.Cache("go-mod")
//
//	s.Task("test").
//	    Container("golang:1.21").
//	    Mount(src, "/src").
//	    MountCache(cache, "/go/pkg/mod").
//	    Workdir("/src").
//	    Run("go test ./...")
//	s.Emit()
//
// Or use language presets:
//
//	s := sykli.New()
//	s.Go().Test()
//	s.Go().Build("./app").After("test")
//	s.Emit()
package sykli

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
)

// =============================================================================
// PIPELINE
// =============================================================================

// Pipeline represents a CI pipeline with tasks and resources.
type Pipeline struct {
	tasks  []*Task
	dirs   []*Directory
	caches []*CacheVolume
}

// New creates a new pipeline.
func New() *Pipeline {
	return &Pipeline{
		tasks:  make([]*Task, 0),
		dirs:   make([]*Directory, 0),
		caches: make([]*CacheVolume, 0),
	}
}

// =============================================================================
// RESOURCES
// =============================================================================

// Directory represents a local directory resource.
type Directory struct {
	pipeline *Pipeline
	path     string
	globs    []string
}

// Dir creates a directory resource.
func (p *Pipeline) Dir(path string) *Directory {
	if path == "" {
		panic("directory path cannot be empty")
	}
	d := &Directory{
		pipeline: p,
		path:     path,
		globs:    make([]string, 0),
	}
	p.dirs = append(p.dirs, d)
	return d
}

// Glob adds glob patterns to filter the directory.
func (d *Directory) Glob(patterns ...string) *Directory {
	d.globs = append(d.globs, patterns...)
	return d
}

// ID returns a unique identifier for this directory.
func (d *Directory) ID() string {
	return "src:" + d.path
}

// CacheVolume represents a named cache volume.
type CacheVolume struct {
	pipeline *Pipeline
	name     string
}

// Cache creates a named cache volume.
func (p *Pipeline) Cache(name string) *CacheVolume {
	if name == "" {
		panic("cache name cannot be empty")
	}
	c := &CacheVolume{
		pipeline: p,
		name:     name,
	}
	p.caches = append(p.caches, c)
	return c
}

// ID returns the cache name.
func (c *CacheVolume) ID() string {
	return c.name
}

// =============================================================================
// TASK
// =============================================================================

// Mount represents a filesystem mount in a container.
type Mount struct {
	// resource is the ID of the resource being mounted (e.g., "src:." for directories, cache name for caches)
	resource string
	// path is the mount path inside the container (must be absolute)
	path string
	// mountType specifies the type of mount: "directory" or "cache"
	mountType string
	// sourcePath is the host path for directories (not used for caches)
	sourcePath string
}

// Task represents a single task in the pipeline.
type Task struct {
	pipeline  *Pipeline
	name      string
	command   string
	container string
	workdir   string
	env       map[string]string
	mounts    []Mount
	inputs    []string
	outputs   map[string]string
	dependsOn []string
}

// Task creates a new task with the given name.
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
		pipeline: p,
		name:     name,
		env:      make(map[string]string),
		mounts:   make([]Mount, 0),
		outputs:  make(map[string]string),
	}
	p.tasks = append(p.tasks, t)
	return t
}

// Run sets the command for this task.
func (t *Task) Run(cmd string) *Task {
	if cmd == "" {
		panic("command cannot be empty")
	}
	t.command = cmd
	return t
}

// Container sets the container image for this task.
func (t *Task) Container(image string) *Task {
	if image == "" {
		panic("container image cannot be empty")
	}
	t.container = image
	return t
}

// Mount mounts a directory into the container.
func (t *Task) Mount(dir *Directory, path string) *Task {
	if dir == nil {
		panic("directory cannot be nil")
	}
	if path == "" || path[0] != '/' {
		panic("container mount path must be absolute (start with /)")
	}
	t.mounts = append(t.mounts, Mount{
		resource:   dir.ID(),
		path:       path,
		mountType:  "directory",
		sourcePath: dir.path,
	})
	return t
}

// MountCache mounts a cache volume into the container.
func (t *Task) MountCache(cache *CacheVolume, path string) *Task {
	if cache == nil {
		panic("cache cannot be nil")
	}
	if path == "" || path[0] != '/' {
		panic("container mount path must be absolute (start with /)")
	}
	t.mounts = append(t.mounts, Mount{
		resource:  cache.ID(),
		path:      path,
		mountType: "cache",
	})
	return t
}

// Workdir sets the working directory inside the container.
func (t *Task) Workdir(path string) *Task {
	t.workdir = path
	return t
}

// Env sets an environment variable.
func (t *Task) Env(key, value string) *Task {
	if key == "" {
		panic("environment variable key cannot be empty")
	}
	t.env[key] = value
	return t
}

// Inputs sets the input file patterns for caching (v1 style).
func (t *Task) Inputs(patterns ...string) *Task {
	t.inputs = append(t.inputs, patterns...)
	return t
}

// Output sets a named output path.
func (t *Task) Output(name, path string) *Task {
	if name == "" || path == "" {
		fmt.Printf("Warning: Output() called with empty name or path; ignoring. name='%s', path='%s'\n", name, path)
		return t
	}
	t.outputs[name] = path
	return t
}

// Outputs sets output paths (v1 style, for backward compat).
func (t *Task) Outputs(paths ...string) *Task {
	for i, path := range paths {
		t.outputs[fmt.Sprintf("output_%d", i)] = path
	}
	return t
}

// After sets dependencies - this task runs after the named tasks.
func (t *Task) After(tasks ...string) *Task {
	t.dependsOn = append(t.dependsOn, tasks...)
	return t
}

// =============================================================================
// LANGUAGE PRESETS
// =============================================================================

// GoPreset provides convenience methods for Go projects.
type GoPreset struct {
	p *Pipeline
}

// Go returns a Go preset builder.
func (p *Pipeline) Go() *GoPreset {
	return &GoPreset{p: p}
}

// GoInputs returns standard input patterns for Go projects.
func GoInputs() []string {
	return []string{"**/*.go", "go.mod", "go.sum"}
}

// Test adds a "go test" task with standard Go inputs.
func (g *GoPreset) Test() *Task {
	return g.p.Task("test").Run("go test ./...").Inputs(GoInputs()...)
}

// Lint adds a "go vet" task with standard Go inputs.
func (g *GoPreset) Lint() *Task {
	return g.p.Task("lint").Run("go vet ./...").Inputs(GoInputs()...)
}

// Build adds a "go build" task with the given output path.
func (g *GoPreset) Build(output string) *Task {
	return g.p.Task("build").
		Run("go build -o " + output).
		Inputs(GoInputs()...).
		Outputs(output)
}

// =============================================================================
// EMIT
// =============================================================================

// Emit outputs the pipeline as JSON if --emit flag is present.
// Call this at the end of your sykli.go file.
func (p *Pipeline) Emit() {
	for _, arg := range os.Args[1:] {
		if arg == "--emit" {
			if err := p.EmitTo(os.Stdout); err != nil {
				fmt.Fprintf(os.Stderr, "error: %v\n", err)
				os.Exit(1)
			}
			os.Exit(0)
		}
	}
}

// EmitTo writes the pipeline JSON to the given writer.
func (p *Pipeline) EmitTo(w io.Writer) error {
	// Validate
	taskNames := make(map[string]bool)
	for _, t := range p.tasks {
		taskNames[t.name] = true
	}
	for _, t := range p.tasks {
		if t.command == "" {
			return fmt.Errorf("task %q has no command", t.name)
		}
		for _, dep := range t.dependsOn {
			if !taskNames[dep] {
				return fmt.Errorf("task %q depends on unknown task %q", t.name, dep)
			}
		}
	}

	// Detect version based on usage
	version := "1"
	hasV2Features := len(p.dirs) > 0 || len(p.caches) > 0
	for _, t := range p.tasks {
		if t.container != "" || len(t.mounts) > 0 {
			hasV2Features = true
			break
		}
	}
	if hasV2Features {
		version = "2"
	}

	// Build JSON output
	type jsonMount struct {
		Resource string `json:"resource"`
		Path     string `json:"path"`
		Type     string `json:"type"`
	}

	type jsonTask struct {
		Name      string            `json:"name"`
		Command   string            `json:"command"`
		Container string            `json:"container,omitempty"`
		Workdir   string            `json:"workdir,omitempty"`
		Env       map[string]string `json:"env,omitempty"`
		Mounts    []jsonMount       `json:"mounts,omitempty"`
		Inputs    []string          `json:"inputs,omitempty"`
		Outputs   map[string]string `json:"outputs,omitempty"`
		DependsOn []string          `json:"depends_on,omitempty"`
	}

	type jsonResource struct {
		Type  string   `json:"type"`
		Path  string   `json:"path,omitempty"`
		Name  string   `json:"name,omitempty"`
		Globs []string `json:"globs,omitempty"`
	}

	type jsonPipeline struct {
		Version   string                  `json:"version"`
		Resources map[string]jsonResource `json:"resources,omitempty"`
		Tasks     []jsonTask              `json:"tasks"`
	}

	// Build resources map
	var resources map[string]jsonResource
	if hasV2Features {
		resources = make(map[string]jsonResource)
		for _, d := range p.dirs {
			resources[d.ID()] = jsonResource{
				Type:  "directory",
				Path:  d.path,
				Globs: d.globs,
			}
		}
		for _, c := range p.caches {
			resources[c.ID()] = jsonResource{
				Type: "cache",
				Name: c.name,
			}
		}
	}

	// Build tasks
	tasks := make([]jsonTask, len(p.tasks))
	for i, t := range p.tasks {
		var mounts []jsonMount
		if len(t.mounts) > 0 {
			mounts = make([]jsonMount, len(t.mounts))
			for j, m := range t.mounts {
				mounts[j] = jsonMount{
					Resource: m.resource,
					Path:     m.path,
					Type:     m.mountType,
				}
			}
		}

		var env map[string]string
		if len(t.env) > 0 {
			env = t.env
		}

		var outputs map[string]string
		if len(t.outputs) > 0 {
			outputs = t.outputs
		}

		tasks[i] = jsonTask{
			Name:      t.name,
			Command:   t.command,
			Container: t.container,
			Workdir:   t.workdir,
			Env:       env,
			Mounts:    mounts,
			Inputs:    t.inputs,
			Outputs:   outputs,
			DependsOn: t.dependsOn,
		}
	}

	out := jsonPipeline{
		Version:   version,
		Resources: resources,
		Tasks:     tasks,
	}

	return json.NewEncoder(w).Encode(out)
}
