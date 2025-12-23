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
	"time"

	"github.com/rs/zerolog"
)

// Logger for the SDK - pretty console output by default
var log zerolog.Logger

func init() {
	// Pretty console output with colors
	output := zerolog.ConsoleWriter{
		Out:        os.Stderr,
		TimeFormat: time.Kitchen,
		NoColor:    false,
	}
	log = zerolog.New(output).With().Timestamp().Logger()

	// Set level from environment (SYKLI_DEBUG=1 for debug)
	if os.Getenv("SYKLI_DEBUG") != "" {
		zerolog.SetGlobalLevel(zerolog.DebugLevel)
	} else {
		zerolog.SetGlobalLevel(zerolog.InfoLevel)
	}
}

// =============================================================================
// PIPELINE
// =============================================================================

// Pipeline represents a CI pipeline with tasks and resources.
type Pipeline struct {
	tasks     []*Task
	dirs      []*Directory
	caches    []*CacheVolume
	templates map[string]*Template
}

// New creates a new pipeline.
func New() *Pipeline {
	return &Pipeline{
		tasks:     make([]*Task, 0),
		dirs:      make([]*Directory, 0),
		caches:    make([]*CacheVolume, 0),
		templates: make(map[string]*Template),
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
		log.Panic().Msg("directory path cannot be empty")
	}
	d := &Directory{
		pipeline: p,
		path:     path,
		globs:    make([]string, 0),
	}
	log.Debug().Str("path", path).Msg("registered directory")
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
		log.Panic().Msg("cache name cannot be empty")
	}
	c := &CacheVolume{
		pipeline: p,
		name:     name,
	}
	log.Debug().Str("name", name).Msg("registered cache")
	p.caches = append(p.caches, c)
	return c
}

// ID returns the cache name.
func (c *CacheVolume) ID() string {
	return c.name
}

// =============================================================================
// TEMPLATE
// =============================================================================

// Template represents a reusable task configuration.
// Templates allow you to define common settings (container, mounts, env)
// that can be inherited by multiple tasks via From().
type Template struct {
	pipeline  *Pipeline
	name      string
	container string
	workdir   string
	env       map[string]string
	mounts    []Mount
}

// Template creates a new reusable task template.
func (p *Pipeline) Template(name string) *Template {
	if name == "" {
		log.Panic().Msg("template name cannot be empty")
	}
	if _, exists := p.templates[name]; exists {
		log.Panic().Str("template", name).Msg("template already exists")
	}
	t := &Template{
		pipeline: p,
		name:     name,
		env:      make(map[string]string),
		mounts:   make([]Mount, 0),
	}
	log.Debug().Str("template", name).Msg("registered template")
	p.templates[name] = t
	return t
}

// Container sets the container image for tasks using this template.
func (t *Template) Container(image string) *Template {
	if image == "" {
		log.Panic().Str("template", t.name).Msg("container image cannot be empty")
	}
	t.container = image
	return t
}

// Workdir sets the working directory for tasks using this template.
func (t *Template) Workdir(path string) *Template {
	t.workdir = path
	return t
}

// Env sets an environment variable for tasks using this template.
func (t *Template) Env(key, value string) *Template {
	if key == "" {
		log.Panic().Str("template", t.name).Msg("environment variable key cannot be empty")
	}
	t.env[key] = value
	return t
}

// Mount adds a directory mount for tasks using this template.
func (t *Template) Mount(dir *Directory, path string) *Template {
	if dir == nil {
		log.Panic().Str("template", t.name).Msg("directory cannot be nil")
	}
	if path == "" || path[0] != '/' {
		log.Panic().Str("template", t.name).Str("path", path).Msg("mount path must be absolute")
	}
	t.mounts = append(t.mounts, Mount{
		resource:   dir.ID(),
		path:       path,
		mountType:  "directory",
		sourcePath: dir.path,
	})
	return t
}

// MountCache adds a cache mount for tasks using this template.
func (t *Template) MountCache(cache *CacheVolume, path string) *Template {
	if cache == nil {
		log.Panic().Str("template", t.name).Msg("cache cannot be nil")
	}
	if path == "" || path[0] != '/' {
		log.Panic().Str("template", t.name).Str("path", path).Msg("mount path must be absolute")
	}
	t.mounts = append(t.mounts, Mount{
		resource:  cache.ID(),
		path:      path,
		mountType: "cache",
	})
	return t
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

// Service represents a service container that runs alongside a task.
type Service struct {
	image string
	name  string
}

// TaskInput represents an input artifact from another task's output.
type TaskInput struct {
	fromTask   string // Name of the task that produces the output
	outputName string // Name of the output from that task
	destPath   string // Path where the artifact should be available
}

// Task represents a single task in the pipeline.
type Task struct {
	pipeline   *Pipeline
	name       string
	command    string
	container  string
	workdir    string
	env        map[string]string
	mounts     []Mount
	inputs     []string      // v1-style input file patterns
	taskInputs []TaskInput   // v2-style inputs from other tasks
	outputs    map[string]string
	dependsOn  []string
	when       string
	secrets    []string
	matrix     map[string][]string
	services   []Service
	retry      int
	timeout    int // seconds
}

// Task creates a new task with the given name.
func (p *Pipeline) Task(name string) *Task {
	if name == "" {
		log.Panic().Msg("task name cannot be empty")
	}
	for _, existing := range p.tasks {
		if existing.name == name {
			log.Panic().Str("task", name).Msg("task already exists")
		}
	}
	t := &Task{
		pipeline: p,
		name:     name,
		env:      make(map[string]string),
		mounts:   make([]Mount, 0),
		outputs:  make(map[string]string),
	}
	log.Debug().Str("task", name).Msg("registered task")
	p.tasks = append(p.tasks, t)
	return t
}

// From applies a template's configuration to this task.
// Template settings are applied first, then task-specific settings override them.
func (t *Task) From(tmpl *Template) *Task {
	if tmpl == nil {
		log.Panic().Str("task", t.name).Msg("template cannot be nil")
	}

	// Apply template settings (task settings will override these)
	if tmpl.container != "" && t.container == "" {
		t.container = tmpl.container
	}
	if tmpl.workdir != "" && t.workdir == "" {
		t.workdir = tmpl.workdir
	}

	// Merge env: template first, then task overrides
	for k, v := range tmpl.env {
		if _, exists := t.env[k]; !exists {
			t.env[k] = v
		}
	}

	// Prepend template mounts (task mounts come after)
	if len(tmpl.mounts) > 0 {
		t.mounts = append(tmpl.mounts, t.mounts...)
	}

	log.Debug().Str("task", t.name).Str("template", tmpl.name).Msg("applied template")
	return t
}

// Name returns the task's name for use in dependencies.
func (t *Task) Name() string {
	return t.name
}

// Run sets the command for this task.
func (t *Task) Run(cmd string) *Task {
	if cmd == "" {
		log.Panic().Str("task", t.name).Msg("command cannot be empty")
	}
	t.command = cmd
	return t
}

// Container sets the container image for this task.
func (t *Task) Container(image string) *Task {
	if image == "" {
		log.Panic().Str("task", t.name).Msg("container image cannot be empty")
	}
	t.container = image
	return t
}

// Mount mounts a directory into the container.
func (t *Task) Mount(dir *Directory, path string) *Task {
	if dir == nil {
		log.Panic().Str("task", t.name).Msg("directory cannot be nil")
	}
	if path == "" || path[0] != '/' {
		log.Panic().Str("task", t.name).Str("path", path).Msg("mount path must be absolute (start with /)")
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
		log.Panic().Str("task", t.name).Msg("cache cannot be nil")
	}
	if path == "" || path[0] != '/' {
		log.Panic().Str("task", t.name).Str("path", path).Msg("mount path must be absolute (start with /)")
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
		log.Panic().Str("task", t.name).Msg("environment variable key cannot be empty")
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
		log.Warn().Str("task", t.name).Str("name", name).Str("path", path).Msg("output() called with empty name or path, ignoring")
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

// InputFrom declares that this task needs an artifact from another task's output.
// This automatically adds a dependency on the source task.
//
// Parameters:
//   - fromTask: name of the task that produces the artifact
//   - outputName: name of the output from that task
//   - destPath: path where the artifact should be available in this task
//
// Example:
//
//	p.Task("build").Run("go build -o /out/app").Output("binary", "/out/app")
//	p.Task("package").InputFrom("build", "binary", "/app").Run("docker build")
func (t *Task) InputFrom(fromTask, outputName, destPath string) *Task {
	if fromTask == "" {
		log.Panic().Str("task", t.name).Msg("InputFrom: fromTask cannot be empty")
	}
	if outputName == "" {
		log.Panic().Str("task", t.name).Msg("InputFrom: outputName cannot be empty")
	}
	if destPath == "" {
		log.Panic().Str("task", t.name).Msg("InputFrom: destPath cannot be empty")
	}

	// Add the input binding
	t.taskInputs = append(t.taskInputs, TaskInput{
		fromTask:   fromTask,
		outputName: outputName,
		destPath:   destPath,
	})

	// Auto-add dependency if not already present
	hasDep := false
	for _, dep := range t.dependsOn {
		if dep == fromTask {
			hasDep = true
			break
		}
	}
	if !hasDep {
		t.dependsOn = append(t.dependsOn, fromTask)
	}

	return t
}

// After sets dependencies - this task runs after the named tasks.
func (t *Task) After(tasks ...string) *Task {
	t.dependsOn = append(t.dependsOn, tasks...)
	return t
}

// When sets a condition for when this task should run.
// The condition is evaluated at runtime based on CI context variables:
//   - branch == 'main' - run only on main branch
//   - branch != 'main' - run on all branches except main
//   - tag != '' - run only when a tag is present
//   - event == 'push' - run only on push events
//   - ci == true - run only in CI environment
func (t *Task) When(condition string) *Task {
	if condition == "" {
		log.Panic().Str("task", t.name).Msg("condition cannot be empty")
	}
	t.when = condition
	return t
}

// Secret declares that this task requires a secret environment variable.
// The secret should be provided by the CI environment (e.g., GitHub Actions secrets).
func (t *Task) Secret(name string) *Task {
	if name == "" {
		log.Panic().Str("task", t.name).Msg("secret name cannot be empty")
	}
	t.secrets = append(t.secrets, name)
	return t
}

// Secrets declares multiple secrets that this task requires.
func (t *Task) Secrets(names ...string) *Task {
	for _, name := range names {
		if name == "" {
			log.Panic().Str("task", t.name).Msg("secret name cannot be empty")
		}
	}
	t.secrets = append(t.secrets, names...)
	return t
}

// Matrix adds a matrix dimension for this task.
// Matrix builds run the task multiple times with different parameter combinations.
// Each dimension's values are exposed as environment variables.
func (t *Task) Matrix(key string, values ...string) *Task {
	if key == "" {
		log.Panic().Str("task", t.name).Msg("matrix key cannot be empty")
	}
	if len(values) == 0 {
		log.Panic().Str("task", t.name).Str("key", key).Msg("matrix values cannot be empty")
	}
	if t.matrix == nil {
		t.matrix = make(map[string][]string)
	}
	t.matrix[key] = values
	return t
}

// Service adds a service container that runs alongside this task.
// Services are background containers (like databases) that run during task execution.
// The service is accessible via its name as hostname.
func (t *Task) Service(image, name string) *Task {
	if image == "" {
		log.Panic().Str("task", t.name).Msg("service image cannot be empty")
	}
	if name == "" {
		log.Panic().Str("task", t.name).Msg("service name cannot be empty")
	}
	t.services = append(t.services, Service{image: image, name: name})
	return t
}

// Retry sets the number of times to retry this task on failure.
func (t *Task) Retry(n int) *Task {
	if n < 0 {
		log.Panic().Str("task", t.name).Int("retry", n).Msg("retry count cannot be negative")
	}
	t.retry = n
	return t
}

// Timeout sets the timeout for this task in seconds.
func (t *Task) Timeout(seconds int) *Task {
	if seconds <= 0 {
		log.Panic().Str("task", t.name).Int("timeout", seconds).Msg("timeout must be positive")
	}
	t.timeout = seconds
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
// COMBINATORS
// =============================================================================

// TaskGroup represents a group of tasks that can be used as a dependency.
// Created by Parallel() and can be passed to After() or Chain().
type TaskGroup struct {
	pipeline *Pipeline
	name     string
	tasks    []*Task
}

// Chain creates a sequential dependency chain: a → b → c
// Each task depends on the previous one.
func (p *Pipeline) Chain(items ...interface{}) {
	var prev interface{}
	for _, item := range items {
		if prev != nil {
			addDependency(item, prev)
		}
		prev = item
	}
}

// Parallel creates a group of tasks that run concurrently.
// Returns a TaskGroup that can be used as a dependency with After().
func (p *Pipeline) Parallel(name string, tasks ...*Task) *TaskGroup {
	return &TaskGroup{
		pipeline: p,
		name:     name,
		tasks:    tasks,
	}
}

// After makes all tasks in this group depend on the given tasks/groups.
func (g *TaskGroup) After(deps ...interface{}) *TaskGroup {
	for _, task := range g.tasks {
		for _, dep := range deps {
			addDependencyToTask(task, dep)
		}
	}
	return g
}

// TaskNames returns the names of all tasks in this group.
// Used internally when this group is used as a dependency.
func (g *TaskGroup) TaskNames() []string {
	names := make([]string, len(g.tasks))
	for i, t := range g.tasks {
		names[i] = t.name
	}
	return names
}

// addDependency adds a dependency from 'to' to 'from'.
// Handles both *Task and *TaskGroup.
func addDependency(to, from interface{}) {
	switch t := to.(type) {
	case *Task:
		addDependencyToTask(t, from)
	case *TaskGroup:
		for _, task := range t.tasks {
			addDependencyToTask(task, from)
		}
	}
}

// addDependencyToTask adds a dependency to a single task.
func addDependencyToTask(task *Task, from interface{}) {
	switch f := from.(type) {
	case *Task:
		task.dependsOn = append(task.dependsOn, f.name)
	case *TaskGroup:
		task.dependsOn = append(task.dependsOn, f.TaskNames()...)
	case string:
		task.dependsOn = append(task.dependsOn, f)
	}
}

// After for Task now accepts TaskGroup in addition to strings.
// This extends the existing After method to work with Parallel groups.
func (t *Task) AfterGroup(groups ...*TaskGroup) *Task {
	for _, g := range groups {
		t.dependsOn = append(t.dependsOn, g.TaskNames()...)
	}
	return t
}

// =============================================================================
// CYCLE DETECTION
// =============================================================================

// Color constants for DFS cycle detection
const (
	white = iota // unvisited
	gray         // currently visiting (in recursion stack)
	black        // completely processed
)

// detectCycle uses DFS to detect cycles in the task dependency graph.
// Returns the cycle path if found, nil otherwise.
func (p *Pipeline) detectCycle() []string {
	// Build adjacency map: task name -> dependencies
	deps := make(map[string][]string)
	for _, t := range p.tasks {
		deps[t.name] = t.dependsOn
	}

	color := make(map[string]int)
	parent := make(map[string]string)

	// Initialize all tasks as white (unvisited)
	for _, t := range p.tasks {
		color[t.name] = white
	}

	// DFS from each unvisited node
	for _, t := range p.tasks {
		if color[t.name] == white {
			if cycle := p.dfsDetectCycle(t.name, deps, color, parent); cycle != nil {
				return cycle
			}
		}
	}

	return nil
}

// dfsDetectCycle performs DFS and returns cycle path if found.
func (p *Pipeline) dfsDetectCycle(node string, deps map[string][]string, color map[string]int, parent map[string]string) []string {
	color[node] = gray

	for _, dep := range deps[node] {
		if color[dep] == gray {
			// Found a cycle - reconstruct the path
			return p.reconstructCycle(node, dep, parent)
		}
		if color[dep] == white {
			parent[dep] = node
			if cycle := p.dfsDetectCycle(dep, deps, color, parent); cycle != nil {
				return cycle
			}
		}
	}

	color[node] = black
	return nil
}

// reconstructCycle builds the cycle path from the detected back edge.
func (p *Pipeline) reconstructCycle(from, to string, parent map[string]string) []string {
	// Cycle: to -> ... -> from -> to
	cycle := []string{to}
	current := from
	for current != to {
		cycle = append([]string{current}, cycle...)
		current = parent[current]
	}
	cycle = append([]string{to}, cycle...) // Close the cycle
	return cycle
}

// formatCyclePath formats a cycle as a readable string: a -> b -> c -> a
func formatCyclePath(cycle []string) string {
	if len(cycle) == 0 {
		return ""
	}
	result := cycle[0]
	for i := 1; i < len(cycle); i++ {
		result += " -> " + cycle[i]
	}
	return result
}

// =============================================================================
// EMIT
// =============================================================================

// Emit outputs the pipeline as JSON if --emit flag is present.
// Call this at the end of your sykli.go file.
func (p *Pipeline) Emit() {
	for _, arg := range os.Args[1:] {
		if arg == "--emit" {
			log.Debug().Int("tasks", len(p.tasks)).Msg("emitting pipeline")
			if err := p.EmitTo(os.Stdout); err != nil {
				log.Fatal().Err(err).Msg("failed to emit pipeline")
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
			log.Error().Str("task", t.name).Msg("task has no command")
			return fmt.Errorf("task %q has no command", t.name)
		}
		for _, dep := range t.dependsOn {
			if !taskNames[dep] {
				log.Error().Str("task", t.name).Str("dependency", dep).Msg("unknown dependency")
				return fmt.Errorf("task %q depends on unknown task %q", t.name, dep)
			}
		}
	}

	// Cycle detection using DFS with three-color marking
	if cycle := p.detectCycle(); cycle != nil {
		cyclePath := formatCyclePath(cycle)
		log.Error().Strs("cycle", cycle).Msg("dependency cycle detected")
		return fmt.Errorf("dependency cycle detected: %s", cyclePath)
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

	type jsonService struct {
		Image string `json:"image"`
		Name  string `json:"name"`
	}

	type jsonTaskInput struct {
		FromTask   string `json:"from_task"`
		OutputName string `json:"output"`
		DestPath   string `json:"dest"`
	}

	type jsonTask struct {
		Name       string              `json:"name"`
		Command    string              `json:"command"`
		Container  string              `json:"container,omitempty"`
		Workdir    string              `json:"workdir,omitempty"`
		Env        map[string]string   `json:"env,omitempty"`
		Mounts     []jsonMount         `json:"mounts,omitempty"`
		Inputs     []string            `json:"inputs,omitempty"`       // v1-style file patterns
		TaskInputs []jsonTaskInput     `json:"task_inputs,omitempty"`  // v2-style inputs from other tasks
		Outputs    map[string]string   `json:"outputs,omitempty"`
		DependsOn  []string            `json:"depends_on,omitempty"`
		When       string              `json:"when,omitempty"`
		Secrets    []string            `json:"secrets,omitempty"`
		Matrix     map[string][]string `json:"matrix,omitempty"`
		Services   []jsonService       `json:"services,omitempty"`
		Retry      int                 `json:"retry,omitempty"`
		Timeout    int                 `json:"timeout,omitempty"`
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

		// Convert taskInputs to JSON
		var taskInputs []jsonTaskInput
		if len(t.taskInputs) > 0 {
			taskInputs = make([]jsonTaskInput, len(t.taskInputs))
			for j, ti := range t.taskInputs {
				taskInputs[j] = jsonTaskInput{
					FromTask:   ti.fromTask,
					OutputName: ti.outputName,
					DestPath:   ti.destPath,
				}
			}
		}

		tasks[i] = jsonTask{
			Name:       t.name,
			Command:    t.command,
			Container:  t.container,
			Workdir:    t.workdir,
			Env:        env,
			Mounts:     mounts,
			Inputs:     t.inputs,     // v1-style file patterns
			TaskInputs: taskInputs,   // v2-style inputs from other tasks
			Outputs:    outputs,
			DependsOn:  t.dependsOn,
			When:       t.when,
			Secrets:    t.secrets,
			Matrix:     t.matrix,
			Retry:      t.retry,
			Timeout:    t.timeout,
			Services: func() []jsonService {
				if len(t.services) == 0 {
					return nil
				}
				svcs := make([]jsonService, len(t.services))
				for j, s := range t.services {
					svcs[j] = jsonService{Image: s.image, Name: s.name}
				}
				return svcs
			}(),
		}
	}

	out := jsonPipeline{
		Version:   version,
		Resources: resources,
		Tasks:     tasks,
	}

	return json.NewEncoder(w).Encode(out)
}
