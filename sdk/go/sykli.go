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
	"sort"
	"strings"
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
	tasks       []*Task
	dirs        []*Directory
	caches      []*CacheVolume
	templates   map[string]*Template
	k8sDefaults *K8sOptions // Pipeline-level K8s defaults
}

// PipelineOption configures a Pipeline.
type PipelineOption func(*Pipeline)

// WithK8sDefaults sets pipeline-level Kubernetes defaults.
// All tasks inherit these settings unless they override them.
//
// Example:
//
//	s := sykli.New(sykli.WithK8sDefaults(sykli.K8sOptions{
//	    Memory: "2Gi",
//	    CPU:    "1",
//	}))
//
//	s.Task("test").Run("go test")                           // inherits 2Gi, 1 CPU
//	s.Task("heavy").K8s(sykli.K8sOptions{Memory: "32Gi"})   // overrides memory
func WithK8sDefaults(opts K8sOptions) PipelineOption {
	return func(p *Pipeline) {
		p.k8sDefaults = &opts
	}
}

// New creates a new pipeline with optional configuration.
func New(opts ...PipelineOption) *Pipeline {
	p := &Pipeline{
		tasks:     make([]*Task, 0),
		dirs:      make([]*Directory, 0),
		caches:    make([]*CacheVolume, 0),
		templates: make(map[string]*Template),
	}
	for _, opt := range opts {
		opt(p)
	}
	return p
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
	if path == "" || path[0] != '/' {
		log.Panic().Str("template", t.name).Str("workdir", path).Msg("workdir must be an absolute, non-empty path")
	}
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

// =============================================================================
// TYPED SECRET REFERENCES
// =============================================================================

// SecretSource identifies where a secret comes from.
type SecretSource int

const (
	// SecretFromEnv reads the secret from an environment variable.
	SecretFromEnv SecretSource = iota
	// SecretFromFile reads the secret from a file.
	SecretFromFile
	// SecretFromVault reads the secret from HashiCorp Vault.
	SecretFromVault
)

// SecretRef is a typed reference to a secret with its source.
//
// Example:
//
//	s.Task("deploy").
//	    SecretFrom("GITHUB_TOKEN", FromEnv("GH_TOKEN")).
//	    SecretFrom("DB_PASSWORD", FromVault("secret/db#password"))
type SecretRef struct {
	// Name is the environment variable name in the task
	Name string
	// Source indicates where the secret comes from
	Source SecretSource
	// Key is the source-specific key (env var name, file path, or vault path)
	Key string
}

// FromEnv creates a secret reference that reads from an environment variable.
//
// Example:
//
//	s.Task("deploy").SecretFrom("TOKEN", FromEnv("GITHUB_TOKEN"))
func FromEnv(envVar string) SecretRef {
	return SecretRef{Source: SecretFromEnv, Key: envVar}
}

// FromFile creates a secret reference that reads from a file.
//
// Example:
//
//	s.Task("deploy").SecretFrom("KEY", FromFile("/run/secrets/api-key"))
func FromFile(path string) SecretRef {
	return SecretRef{Source: SecretFromFile, Key: path}
}

// FromVault creates a secret reference that reads from HashiCorp Vault.
// The path format is "path/to/secret#field".
//
// Example:
//
//	s.Task("deploy").SecretFrom("DB_PASS", FromVault("secret/data/db#password"))
func FromVault(path string) SecretRef {
	return SecretRef{Source: SecretFromVault, Key: path}
}

// =============================================================================
// CONDITION BUILDER (Type-safe conditions)
// =============================================================================

// Condition represents a type-safe condition for when a task should run.
// Use the builder functions (Branch, Tag, Event, etc.) to create conditions.
//
// Example:
//
//	s.Task("deploy").
//	    WhenCond(Branch("main").Or(Tag("v*")))
//
//	s.Task("test").
//	    WhenCond(Not(Branch("wip/*")))
type Condition struct {
	expr string
}

// String returns the condition expression string.
func (c Condition) String() string {
	return c.expr
}

// Or combines conditions with OR logic.
//
// Example:
//
//	Branch("main").Or(Tag("v*"))  // branch == 'main' || tag matches 'v*'
func (c Condition) Or(other Condition) Condition {
	return Condition{expr: fmt.Sprintf("(%s) || (%s)", c.expr, other.expr)}
}

// And combines conditions with AND logic.
//
// Example:
//
//	Branch("main").And(Event("push"))  // branch == 'main' && event == 'push'
func (c Condition) And(other Condition) Condition {
	return Condition{expr: fmt.Sprintf("(%s) && (%s)", c.expr, other.expr)}
}

// Branch creates a condition that matches a branch name or pattern.
// Supports glob patterns like "feature/*".
//
// Example:
//
//	Branch("main")           // branch == 'main'
//	Branch("release/*")      // branch matches 'release/*'
func Branch(pattern string) Condition {
	if strings.Contains(pattern, "*") {
		return Condition{expr: fmt.Sprintf("branch matches '%s'", pattern)}
	}
	return Condition{expr: fmt.Sprintf("branch == '%s'", pattern)}
}

// Tag creates a condition that matches a tag name or pattern.
// Supports glob patterns like "v*".
//
// Example:
//
//	Tag("v*")        // tag matches 'v*'
//	Tag("v1.0.0")    // tag == 'v1.0.0'
func Tag(pattern string) Condition {
	if pattern == "" {
		return Condition{expr: "tag != ''"}
	}
	if strings.Contains(pattern, "*") {
		return Condition{expr: fmt.Sprintf("tag matches '%s'", pattern)}
	}
	return Condition{expr: fmt.Sprintf("tag == '%s'", pattern)}
}

// HasTag creates a condition that matches when any tag is present.
//
// Example:
//
//	HasTag()  // tag != ''
func HasTag() Condition {
	return Condition{expr: "tag != ''"}
}

// Event creates a condition that matches a CI event type.
//
// Example:
//
//	Event("push")           // event == 'push'
//	Event("pull_request")   // event == 'pull_request'
func Event(eventType string) Condition {
	return Condition{expr: fmt.Sprintf("event == '%s'", eventType)}
}

// InCI creates a condition that matches when running in CI.
//
// Example:
//
//	InCI()  // ci == true
func InCI() Condition {
	return Condition{expr: "ci == true"}
}

// Not negates a condition.
//
// Example:
//
//	Not(Branch("wip/*"))  // !(branch matches 'wip/*')
func Not(c Condition) Condition {
	return Condition{expr: fmt.Sprintf("!(%s)", c.expr)}
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

// =============================================================================
// AI-NATIVE METADATA
// =============================================================================

// Criticality represents task importance for AI prioritization.
type Criticality string

const (
	CriticalityHigh   Criticality = "high"
	CriticalityMedium Criticality = "medium"
	CriticalityLow    Criticality = "low"
)

// OnFailAction specifies what AI should do when task fails.
type OnFailAction string

const (
	OnFailAnalyze OnFailAction = "analyze" // AI should analyze failure
	OnFailRetry   OnFailAction = "retry"   // AI should retry with modifications
	OnFailSkip    OnFailAction = "skip"    // AI can skip without analysis
)

// SelectMode specifies how AI should select this task.
type SelectMode string

const (
	SelectSmart  SelectMode = "smart"  // Only run if covers changed files
	SelectAlways SelectMode = "always" // Always run regardless of changes
	SelectManual SelectMode = "manual" // Only run when explicitly requested
)

// Semantic holds metadata for AI understanding of the task.
type Semantic struct {
	covers      []string
	intent      string
	criticality Criticality
}

// AiHooks holds behavioral hints for AI assistants.
type AiHooks struct {
	onFail OnFailAction
	sel    SelectMode
}

// Task represents a single task in the pipeline.
type Task struct {
	pipeline     *Pipeline
	name         string
	command      string
	container    string
	workdir      string
	env          map[string]string
	mounts       []Mount
	inputs       []string      // v1-style input file patterns
	taskInputs   []TaskInput   // v2-style inputs from other tasks
	outputs      map[string]string
	dependsOn    []string
	when         string
	whenCond     Condition              // Type-safe condition (alternative to string)
	secrets      []string               // v1-style secret names
	secretRefs   []SecretRef            // v2-style typed secret references
	matrix       map[string][]string
	services     []Service
	retry        int
	timeout      int                    // seconds
	k8sOptions   *K8sOptions            // Target-specific K8s options
	k8sRaw       string                 // Raw K8s JSON for advanced options
	targetName   string                 // Per-task target override
	requires     []string               // Required node labels for placement
	// AI-native fields
	semantic     Semantic
	aiHooks      AiHooks
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
		mounts := make([]Mount, len(tmpl.mounts))
		copy(mounts, tmpl.mounts)
		t.mounts = append(mounts, t.mounts...)
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

// MountCwd mounts the current working directory to /work and sets workdir.
// This is a convenience method that combines Mount + Workdir for the common case.
func (t *Task) MountCwd() *Task {
	t.mounts = append(t.mounts, Mount{
		resource:   "src:.",
		path:       "/work",
		mountType:  "directory",
		sourcePath: ".",
	})
	t.workdir = "/work"
	return t
}

// MountCwdAt mounts the current working directory to a custom path and sets workdir.
func (t *Task) MountCwdAt(containerPath string) *Task {
	if containerPath == "" || containerPath[0] != '/' {
		log.Panic().Str("task", t.name).Str("path", containerPath).Msg("mount path must be absolute (start with /)")
	}
	t.mounts = append(t.mounts, Mount{
		resource:   "src:.",
		path:       containerPath,
		mountType:  "directory",
		sourcePath: ".",
	})
	t.workdir = containerPath
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

// Requires declares node labels that must be present for this task to run.
// Tasks with requires will only run on nodes that have all specified labels.
//
// Example:
//
//	s.Task("train").
//	    Run("python train.py").
//	    Requires("gpu", "docker")
//
//	s.Task("build").
//	    Run("docker build .").
//	    Requires("docker")
func (t *Task) Requires(labels ...string) *Task {
	for _, label := range labels {
		if label == "" {
			log.Panic().Str("task", t.name).Msg("label cannot be empty")
		}
	}
	t.requires = append(t.requires, labels...)
	return t
}

// =============================================================================
// AI-NATIVE METHODS
// =============================================================================

// Covers sets the file patterns this task tests or affects.
// Used for smart task selection - when files change, AI can identify
// which tasks are relevant.
//
// Example:
//
//	s.Task("auth-test").
//	    Run("go test ./auth/...").
//	    Covers("src/auth/*", "src/lib/session.go")
func (t *Task) Covers(patterns ...string) *Task {
	t.semantic.covers = append(t.semantic.covers, patterns...)
	return t
}

// Intent sets a human-readable description of what this task does.
// Helps AI assistants understand the purpose of the task.
//
// Example:
//
//	s.Task("auth-test").
//	    Run("go test ./auth/...").
//	    Intent("Unit tests for authentication module")
func (t *Task) Intent(description string) *Task {
	t.semantic.intent = description
	return t
}

// Critical marks this task as high-criticality for prioritization.
// Shorthand for Criticality(CriticalityHigh).
//
// Example:
//
//	s.Task("security-scan").Run("snyk test").Critical()
func (t *Task) Critical() *Task {
	t.semantic.criticality = CriticalityHigh
	return t
}

// SetCriticality sets the criticality level for this task.
// Use Critical() as shorthand for high criticality.
//
// Example:
//
//	s.Task("lint").Run("golangci-lint run").SetCriticality(CriticalityLow)
func (t *Task) SetCriticality(c Criticality) *Task {
	t.semantic.criticality = c
	return t
}

// OnFail sets what AI should do when this task fails.
//
// Example:
//
//	s.Task("test").Run("go test").OnFail(OnFailAnalyze)
//	s.Task("lint").Run("golangci-lint run").OnFail(OnFailSkip)
func (t *Task) OnFail(action OnFailAction) *Task {
	t.aiHooks.onFail = action
	return t
}

// SelectMode sets how AI should select this task for execution.
//
// Example:
//
//	s.Task("test").
//	    Run("go test ./...").
//	    Covers("**/*.go").
//	    SelectMode(SelectSmart)  // Only run when Go files change
//
//	s.Task("deploy").
//	    Run("kubectl apply -f k8s/").
//	    SelectMode(SelectManual)  // Only run when explicitly requested
func (t *Task) SelectMode(mode SelectMode) *Task {
	t.aiHooks.sel = mode
	return t
}

// Smart enables smart task selection based on covers patterns.
// Shorthand for SelectMode(SelectSmart).
//
// Example:
//
//	s.Task("auth-test").
//	    Run("go test ./auth/...").
//	    Covers("src/auth/*").
//	    Smart()
func (t *Task) Smart() *Task {
	t.aiHooks.sel = SelectSmart
	return t
}

// SecretFrom declares a typed secret reference with explicit source.
// This provides better DX than plain secret names by making the source explicit.
//
// Example:
//
//	s.Task("deploy").
//	    SecretFrom("GITHUB_TOKEN", FromEnv("GH_TOKEN")).
//	    SecretFrom("DB_PASSWORD", FromVault("secret/data/db#password")).
//	    SecretFrom("API_KEY", FromFile("/run/secrets/api-key"))
func (t *Task) SecretFrom(name string, ref SecretRef) *Task {
	if name == "" {
		log.Panic().Str("task", t.name).Msg("secret name cannot be empty")
	}
	if ref.Key == "" {
		log.Panic().Str("task", t.name).Str("secret", name).Msg("secret key cannot be empty")
	}
	ref.Name = name
	t.secretRefs = append(t.secretRefs, ref)
	return t
}

// WhenCond sets a type-safe condition for when this task should run.
// This is an alternative to When() that catches errors at compile time.
//
// Example:
//
//	s.Task("deploy").
//	    WhenCond(Branch("main").Or(Tag("v*")))
//
//	s.Task("test").
//	    WhenCond(Not(Branch("wip/*")).And(Event("push")))
func (t *Task) WhenCond(c Condition) *Task {
	t.whenCond = c
	return t
}

// Target sets the target for this specific task, overriding the pipeline default.
// This enables hybrid pipelines where different tasks run on different targets.
//
// Example:
//
//	s.Task("test").Run("go test").Target("local")
//	s.Task("deploy").Run("kubectl apply").Target("k8s")
func (t *Task) Target(name string) *Task {
	if name == "" {
		log.Panic().Str("task", t.name).Msg("target name cannot be empty")
	}
	t.targetName = name
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
// MATRIX BUILDS
// =============================================================================

// Matrix creates tasks for each value in the matrix, using a generator function.
// Useful for testing across multiple versions or configurations.
//
// Example:
//
//	s.Matrix("test", []string{"1.21", "1.22", "1.23"}, func(version string) *Task {
//	    return s.Task("test-go-"+version).
//	        Container("golang:"+version).
//	        MountCwd().
//	        Run("go test ./...")
//	})
func (p *Pipeline) Matrix(name string, values []string, generator func(string) *Task) *TaskGroup {
	if len(values) == 0 {
		panic("Matrix: values must not be empty")
	}
	tasks := make([]*Task, 0, len(values))
	for _, v := range values {
		task := generator(v)
		if task != nil {
			tasks = append(tasks, task)
		}
	}
	return &TaskGroup{
		pipeline: p,
		name:     name,
		tasks:    tasks,
	}
}

// MatrixMap creates tasks for each key-value pair in the matrix.
// The generator receives both the key and value.
//
// Example:
//
//	s.MatrixMap("deploy", map[string]string{
//	    "staging": "staging.example.com",
//	    "prod":    "prod.example.com",
//	}, func(env, host string) *Task {
//	    return s.Task("deploy-"+env).Run("deploy --host "+host)
//	})
func (p *Pipeline) MatrixMap(name string, values map[string]string, generator func(key, value string) *Task) *TaskGroup {
	if len(values) == 0 {
		panic("MatrixMap: values must not be empty")
	}

	// Sort keys for deterministic iteration order
	keys := make([]string, 0, len(values))
	for k := range values {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	tasks := make([]*Task, 0, len(values))
	for _, k := range keys {
		task := generator(k, values[k])
		if task != nil {
			tasks = append(tasks, task)
		}
	}
	return &TaskGroup{
		pipeline: p,
		name:     name,
		tasks:    tasks,
	}
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
// EXPLAIN (Dry-run mode)
// =============================================================================

// ExplainContext provides runtime context for evaluating conditions.
// Pass nil to use default (empty) context.
type ExplainContext struct {
	Branch string
	Tag    string
	Event  string
	CI     bool
}

// Explain prints a human-readable execution plan without running anything.
// This is useful for debugging pipelines and understanding what will run.
//
// The output shows:
//   - Task execution order (topologically sorted)
//   - Dependencies between tasks
//   - Conditions and whether they would be skipped
//   - Target overrides
//
// Example:
//
//	s := sykli.New()
//	s.Task("test").Run("go test")
//	s.Task("build").Run("go build").After("test")
//	s.Task("deploy").Run("kubectl apply").After("build").WhenCond(Branch("main"))
//
//	s.Explain(&sykli.ExplainContext{Branch: "feature/foo"})
//	// Output:
//	// Pipeline Execution Plan
//	// =======================
//	// 1. test
//	//    Command: go test
//	//
//	// 2. build (after: test)
//	//    Command: go build
//	//
//	// 3. deploy (after: build) [SKIPPED: branch != 'main']
//	//    Command: kubectl apply
//	//    Condition: branch == 'main'
func (p *Pipeline) Explain(ctx *ExplainContext) {
	p.ExplainTo(os.Stdout, ctx)
}

// ExplainTo writes the execution plan to the given writer.
func (p *Pipeline) ExplainTo(w io.Writer, ctx *ExplainContext) {
	if ctx == nil {
		ctx = &ExplainContext{}
	}

	// Topological sort
	sorted := p.topologicalSort()

	fmt.Fprintln(w, "Pipeline Execution Plan")
	fmt.Fprintln(w, "=======================")

	for i, t := range sorted {
		// Build task header
		header := fmt.Sprintf("%d. %s", i+1, t.name)

		// Add dependencies
		if len(t.dependsOn) > 0 {
			header += fmt.Sprintf(" (after: %s)", strings.Join(t.dependsOn, ", "))
		}

		// Add target override
		if t.targetName != "" {
			header += fmt.Sprintf(" [target: %s]", t.targetName)
		}

		// Check if task would be skipped
		condition := t.getEffectiveCondition()
		skipped, skipReason := p.wouldSkip(t, ctx)
		if skipped {
			header += fmt.Sprintf(" [SKIPPED: %s]", skipReason)
		}

		fmt.Fprintln(w, header)
		fmt.Fprintf(w, "   Command: %s\n", t.command)

		if condition != "" {
			fmt.Fprintf(w, "   Condition: %s\n", condition)
		}

		if len(t.secretRefs) > 0 {
			fmt.Fprint(w, "   Secrets: ")
			for i, ref := range t.secretRefs {
				if i > 0 {
					fmt.Fprint(w, ", ")
				}
				switch ref.Source {
				case SecretFromEnv:
					fmt.Fprintf(w, "%s (env:%s)", ref.Name, ref.Key)
				case SecretFromFile:
					fmt.Fprintf(w, "%s (file:%s)", ref.Name, ref.Key)
				case SecretFromVault:
					fmt.Fprintf(w, "%s (vault:%s)", ref.Name, ref.Key)
				}
			}
			fmt.Fprintln(w)
		} else if len(t.secrets) > 0 {
			fmt.Fprintf(w, "   Secrets: %s\n", strings.Join(t.secrets, ", "))
		}

		fmt.Fprintln(w)
	}
}

// getEffectiveCondition returns the condition string (from whenCond or when).
func (t *Task) getEffectiveCondition() string {
	if t.whenCond.expr != "" {
		return t.whenCond.expr
	}
	return t.when
}

// wouldSkip checks if a task would be skipped given the context.
func (p *Pipeline) wouldSkip(t *Task, ctx *ExplainContext) (bool, string) {
	condition := t.getEffectiveCondition()
	if condition == "" {
		return false, ""
	}

	// Simple condition evaluation (handles common cases)
	// More complex conditions would need a proper expression parser
	condition = strings.TrimSpace(condition)

	// branch == 'value'
	if strings.HasPrefix(condition, "branch == '") {
		expected := strings.TrimPrefix(condition, "branch == '")
		expected = strings.TrimSuffix(expected, "'")
		if ctx.Branch != expected {
			return true, fmt.Sprintf("branch is '%s', not '%s'", ctx.Branch, expected)
		}
	}

	// branch != 'value'
	if strings.HasPrefix(condition, "branch != '") {
		excluded := strings.TrimPrefix(condition, "branch != '")
		excluded = strings.TrimSuffix(excluded, "'")
		if ctx.Branch == excluded {
			return true, fmt.Sprintf("branch is '%s'", ctx.Branch)
		}
	}

	// tag != '' (has tag)
	if condition == "tag != ''" && ctx.Tag == "" {
		return true, "no tag present"
	}

	// ci == true
	if condition == "ci == true" && !ctx.CI {
		return true, "not running in CI"
	}

	return false, ""
}

// topologicalSort returns tasks in dependency order.
func (p *Pipeline) topologicalSort() []*Task {
	// Build task map and dependency graph
	taskMap := make(map[string]*Task)
	inDegree := make(map[string]int)
	for _, t := range p.tasks {
		taskMap[t.name] = t
		inDegree[t.name] = 0
	}

	// Count incoming edges
	for _, t := range p.tasks {
		for _, dep := range t.dependsOn {
			inDegree[t.name]++
			_ = dep // just counting
		}
	}

	// Kahn's algorithm
	var queue []string
	for name, degree := range inDegree {
		if degree == 0 {
			queue = append(queue, name)
		}
	}

	var sorted []*Task
	for len(queue) > 0 {
		// Pop from queue
		name := queue[0]
		queue = queue[1:]
		sorted = append(sorted, taskMap[name])

		// Decrease in-degree of dependents
		for _, t := range p.tasks {
			for _, dep := range t.dependsOn {
				if dep == name {
					inDegree[t.name]--
					if inDegree[t.name] == 0 {
						queue = append(queue, t.name)
					}
				}
			}
		}
	}

	return sorted
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
				suggestion := suggestTaskName(dep, taskNames)
				if suggestion != "" {
					return fmt.Errorf("task %q depends on unknown task %q (did you mean %q?)", t.name, dep, suggestion)
				}
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

	// Validate K8s options (merge defaults first, then validate)
	for _, t := range p.tasks {
		merged := MergeK8sOptions(p.k8sDefaults, t.k8sOptions)
		if errs := ValidateK8sOptions(merged); len(errs) > 0 {
			for _, err := range errs {
				log.Error().Str("task", t.name).Err(err).Msg("K8s validation failed")
			}
			return fmt.Errorf("task %q: %v", t.name, errs[0])
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

	type jsonService struct {
		Image string `json:"image"`
		Name  string `json:"name"`
	}

	type jsonTaskInput struct {
		FromTask   string `json:"from_task"`
		OutputName string `json:"output"`
		DestPath   string `json:"dest"`
	}

	type jsonSecretRef struct {
		Name   string `json:"name"`
		Source string `json:"source"` // "env", "file", "vault"
		Key    string `json:"key"`
	}

	// K8s options JSON - minimal API
	type jsonK8sOptions struct {
		Memory string `json:"memory,omitempty"` // e.g., "4Gi"
		CPU    string `json:"cpu,omitempty"`    // e.g., "2", "500m"
		GPU    int    `json:"gpu,omitempty"`    // NVIDIA GPUs
		Raw    string `json:"raw,omitempty"`    // Escape hatch: raw JSON for advanced options
	}

	// AI-native metadata JSON
	type jsonSemantic struct {
		Covers      []string `json:"covers,omitempty"`
		Intent      string   `json:"intent,omitempty"`
		Criticality string   `json:"criticality,omitempty"`
	}

	type jsonAiHooks struct {
		OnFail string `json:"on_fail,omitempty"`
		Select string `json:"select,omitempty"`
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
		SecretRefs []jsonSecretRef     `json:"secret_refs,omitempty"`  // v2-style typed secrets
		Matrix     map[string][]string `json:"matrix,omitempty"`
		Services   []jsonService       `json:"services,omitempty"`
		Retry      int                 `json:"retry,omitempty"`
		Timeout    int                 `json:"timeout,omitempty"`
		Target     string              `json:"target,omitempty"`       // Per-task target override
		K8s        *jsonK8sOptions     `json:"k8s,omitempty"`          // K8s-specific options
		Requires   []string            `json:"requires,omitempty"`     // Required node labels
		// AI-native fields
		Semantic   *jsonSemantic       `json:"semantic,omitempty"`
		AiHooks    *jsonAiHooks        `json:"ai_hooks,omitempty"`
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

	// convertK8sOptions converts K8sOptions to JSON format
	convertK8sOptions := func(opts *K8sOptions, raw string) *jsonK8sOptions {
		if opts == nil && raw == "" {
			return nil
		}

		result := &jsonK8sOptions{}
		if opts != nil {
			result.Memory = opts.Memory
			result.CPU = opts.CPU
			result.GPU = opts.GPU
		}
		if raw != "" {
			result.Raw = raw
		}

		// Return nil if empty
		if result.Memory == "" && result.CPU == "" && result.GPU == 0 && result.Raw == "" {
			return nil
		}
		return result
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

		// Convert secretRefs to JSON
		var secretRefs []jsonSecretRef
		if len(t.secretRefs) > 0 {
			secretRefs = make([]jsonSecretRef, len(t.secretRefs))
			for j, sr := range t.secretRefs {
				var source string
				switch sr.Source {
				case SecretFromEnv:
					source = "env"
				case SecretFromFile:
					source = "file"
				case SecretFromVault:
					source = "vault"
				}
				secretRefs[j] = jsonSecretRef{
					Name:   sr.Name,
					Source: source,
					Key:    sr.Key,
				}
			}
		}

		// Use whenCond if set, otherwise use when string
		when := t.when
		if t.whenCond.expr != "" {
			when = t.whenCond.expr
		}

		tasks[i] = jsonTask{
			Name:       t.name,
			Command:    t.command,
			Container:  t.container,
			Workdir:    t.workdir,
			Env:        env,
			Mounts:     mounts,
			Inputs:     t.inputs,      // v1-style file patterns
			TaskInputs: taskInputs,    // v2-style inputs from other tasks
			Outputs:    outputs,
			DependsOn:  t.dependsOn,
			When:       when,
			Secrets:    t.secrets,
			SecretRefs: secretRefs,    // v2-style typed secrets
			Matrix:     t.matrix,
			Retry:      t.retry,
			Timeout:    t.timeout,
			Target:     t.targetName,  // Per-task target override
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
			K8s: convertK8sOptions(MergeK8sOptions(p.k8sDefaults, t.k8sOptions), t.k8sRaw),
			Requires: func() []string {
				if len(t.requires) == 0 {
					return nil
				}
				return t.requires
			}(),
			Semantic: func() *jsonSemantic {
				if len(t.semantic.covers) == 0 && t.semantic.intent == "" && t.semantic.criticality == "" {
					return nil
				}
				return &jsonSemantic{
					Covers:      t.semantic.covers,
					Intent:      t.semantic.intent,
					Criticality: string(t.semantic.criticality),
				}
			}(),
			AiHooks: func() *jsonAiHooks {
				if t.aiHooks.onFail == "" && t.aiHooks.sel == "" {
					return nil
				}
				return &jsonAiHooks{
					OnFail: string(t.aiHooks.onFail),
					Select: string(t.aiHooks.sel),
				}
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

// suggestTaskName finds the most similar task name using Levenshtein distance.
// Returns empty string if no good match is found.
func suggestTaskName(unknown string, known map[string]bool) string {
	var best string
	bestScore := 0.0

	for name := range known {
		score := jaroWinkler(unknown, name)
		if score > bestScore && score >= 0.8 {
			bestScore = score
			best = name
		}
	}
	return best
}

// jaroWinkler computes the Jaro-Winkler similarity between two strings (0-1).
func jaroWinkler(s1, s2 string) float64 {
	if s1 == s2 {
		return 1.0
	}
	if len(s1) == 0 || len(s2) == 0 {
		return 0.0
	}

	// Compute Jaro similarity
	matchWindow := max(len(s1), len(s2))/2 - 1
	if matchWindow < 0 {
		matchWindow = 0
	}

	s1Matches := make([]bool, len(s1))
	s2Matches := make([]bool, len(s2))

	matches := 0
	transpositions := 0

	for i := 0; i < len(s1); i++ {
		start := max(0, i-matchWindow)
		end := min(len(s2), i+matchWindow+1)

		for j := start; j < end; j++ {
			if s2Matches[j] || s1[i] != s2[j] {
				continue
			}
			s1Matches[i] = true
			s2Matches[j] = true
			matches++
			break
		}
	}

	if matches == 0 {
		return 0.0
	}

	k := 0
	for i := 0; i < len(s1); i++ {
		if !s1Matches[i] {
			continue
		}
		for !s2Matches[k] {
			k++
		}
		if s1[i] != s2[k] {
			transpositions++
		}
		k++
	}

	jaro := (float64(matches)/float64(len(s1)) +
		float64(matches)/float64(len(s2)) +
		float64(matches-transpositions/2)/float64(matches)) / 3.0

	// Apply Winkler prefix bonus
	prefix := 0
	for i := 0; i < min(4, min(len(s1), len(s2))); i++ {
		if s1[i] == s2[i] {
			prefix++
		} else {
			break
		}
	}

	return jaro + float64(prefix)*0.1*(1-jaro)
}
