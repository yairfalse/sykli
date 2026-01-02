# Sykli Go SDK - API Reference

Complete API documentation for the Sykli Go SDK.

## Table of Contents

- [Pipeline](#pipeline)
- [Task](#task)
- [Template](#template)
- [Resources](#resources)
- [Composition](#composition)
- [Conditions](#conditions)
- [Secrets](#secrets)
- [Kubernetes](#kubernetes)
- [Target Interface](#target-interface)

---

## Pipeline

### New

```go
func New(opts ...PipelineOption) *Pipeline
```

Creates a new pipeline with optional configuration.

**Options:**
- `WithK8sDefaults(K8sTaskOptions)` - Set default K8s options for all tasks

**Example:**
```go
// Basic pipeline
s := sykli.New()

// With K8s defaults
s := sykli.New(sykli.WithK8sDefaults(sykli.K8sTaskOptions{
    Namespace: "ci-jobs",
}))
```

### Task

```go
func (p *Pipeline) Task(name string) *Task
```

Creates a new task. Panics if name is empty or duplicate.

### Template

```go
func (p *Pipeline) Template(name string) *Template
```

Creates a reusable task template.

### Dir

```go
func (p *Pipeline) Dir(path string) *Directory
```

Creates a directory resource for mounting into containers.

### Cache

```go
func (p *Pipeline) Cache(name string) *CacheVolume
```

Creates a named cache volume for persisting data between runs.

### Emit

```go
func (p *Pipeline) Emit()
```

Outputs the pipeline as JSON if `--emit` flag is present. Call this at the end of your `sykli.go`.

### EmitTo

```go
func (p *Pipeline) EmitTo(w io.Writer) error
```

Writes the pipeline JSON to the given writer.

### Explain

```go
func (p *Pipeline) Explain(ctx *ExplainContext)
```

Prints a human-readable execution plan without running anything.

---

## Task

### Run

```go
func (t *Task) Run(cmd string) *Task
```

Sets the command for this task. **Required.**

### Container

```go
func (t *Task) Container(image string) *Task
```

Sets the container image for this task.

### Mount

```go
func (t *Task) Mount(dir *Directory, path string) *Task
```

Mounts a directory into the container. Path must be absolute.

### MountCache

```go
func (t *Task) MountCache(cache *CacheVolume, path string) *Task
```

Mounts a cache volume into the container.

### MountCwd

```go
func (t *Task) MountCwd() *Task
```

Convenience method: mounts current directory to `/work` and sets workdir.

### MountCwdAt

```go
func (t *Task) MountCwdAt(containerPath string) *Task
```

Mounts current directory to a custom path and sets workdir.

### Workdir

```go
func (t *Task) Workdir(path string) *Task
```

Sets the working directory inside the container.

### Env

```go
func (t *Task) Env(key, value string) *Task
```

Sets an environment variable.

### Inputs

```go
func (t *Task) Inputs(patterns ...string) *Task
```

Sets input file patterns for caching. Supports glob patterns (`**/*.go`).

### Output

```go
func (t *Task) Output(name, path string) *Task
```

Declares a named output artifact.

### InputFrom

```go
func (t *Task) InputFrom(fromTask, outputName, destPath string) *Task
```

Consumes an artifact from another task's output. Automatically adds dependency.

### After

```go
func (t *Task) After(tasks ...string) *Task
```

Sets dependencies - this task runs after the named tasks.

### AfterGroup

```go
func (t *Task) AfterGroup(groups ...*TaskGroup) *Task
```

Depends on all tasks in the given groups.

### From

```go
func (t *Task) From(tmpl *Template) *Task
```

Applies a template's configuration. Task settings override template settings.

### When

```go
func (t *Task) When(condition string) *Task
```

Sets a string condition for when this task should run.

### WhenCond

```go
func (t *Task) WhenCond(c Condition) *Task
```

Sets a type-safe condition (compile-time checked).

### Secret

```go
func (t *Task) Secret(name string) *Task
```

Declares that this task requires a secret.

### Secrets

```go
func (t *Task) Secrets(names ...string) *Task
```

Declares multiple required secrets.

### SecretFrom

```go
func (t *Task) SecretFrom(name string, ref SecretRef) *Task
```

Declares a typed secret reference with explicit source.

### Service

```go
func (t *Task) Service(image, name string) *Task
```

Adds a service container (database, cache) that runs alongside this task.

### Matrix

```go
func (t *Task) Matrix(key string, values ...string) *Task
```

Adds a matrix dimension. Creates task variants for each value.

### Retry

```go
func (t *Task) Retry(n int) *Task
```

Sets the number of retry attempts on failure.

### Timeout

```go
func (t *Task) Timeout(seconds int) *Task
```

Sets the task timeout in seconds.

### Target

```go
func (t *Task) Target(name string) *Task
```

Sets the target for this specific task, overriding pipeline default.

### K8s

```go
func (t *Task) K8s(opts K8sTaskOptions) *Task
```

Adds Kubernetes-specific options.

### Name

```go
func (t *Task) Name() string
```

Returns the task's name (for use in dependencies).

---

## Template

Templates provide reusable task configuration.

### Container

```go
func (t *Template) Container(image string) *Template
```

### Workdir

```go
func (t *Template) Workdir(path string) *Template
```

### Env

```go
func (t *Template) Env(key, value string) *Template
```

### Mount

```go
func (t *Template) Mount(dir *Directory, path string) *Template
```

### MountCache

```go
func (t *Template) MountCache(cache *CacheVolume, path string) *Template
```

---

## Resources

### Directory

```go
type Directory struct { /* ... */ }
```

Represents a host directory.

**Methods:**
- `Glob(patterns ...string)` - Filter by glob patterns
- `ID() string` - Returns unique identifier

### CacheVolume

```go
type CacheVolume struct { /* ... */ }
```

Represents a named persistent cache.

**Methods:**
- `ID() string` - Returns cache name

---

## Composition

### Parallel

```go
func (p *Pipeline) Parallel(name string, tasks ...*Task) *TaskGroup
```

Creates a group of tasks that run concurrently.

### Chain

```go
func (p *Pipeline) Chain(items ...interface{})
```

Creates a sequential dependency chain.

### Matrix

```go
func (p *Pipeline) Matrix(name string, values []string, generator func(string) *Task) *TaskGroup
```

Creates tasks for each value using a generator function.

### MatrixMap

```go
func (p *Pipeline) MatrixMap(name string, values map[string]string, generator func(key, value string) *Task) *TaskGroup
```

Creates tasks for each key-value pair.

### TaskGroup

```go
type TaskGroup struct { /* ... */ }
```

A group of tasks created by `Parallel()` or `Matrix()`.

**Methods:**
- `After(deps ...interface{})` - Make all tasks depend on given deps
- `TaskNames() []string` - Get names of all tasks in group

---

## Conditions

### String Conditions

```go
t.When("branch == 'main'")
t.When("tag != ''")
t.When("event == 'push'")
t.When("ci == true")
```

### Type-Safe Conditions

```go
// Builders
Branch(pattern string) Condition
Tag(pattern string) Condition
HasTag() Condition
Event(eventType string) Condition
InCI() Condition
Not(c Condition) Condition

// Combinators
(c Condition).Or(other Condition) Condition
(c Condition).And(other Condition) Condition
```

**Examples:**
```go
WhenCond(Branch("main"))
WhenCond(Tag("v*"))
WhenCond(Branch("main").Or(Tag("v*")))
WhenCond(Not(Branch("wip/*")).And(Event("push")))
```

---

## Secrets

### FromEnv

```go
func FromEnv(envVar string) SecretRef
```

Reads secret from environment variable.

### FromFile

```go
func FromFile(path string) SecretRef
```

Reads secret from file.

### FromVault

```go
func FromVault(path string) SecretRef
```

Reads secret from HashiCorp Vault. Path format: `"path/to/secret#field"`.

---

## Kubernetes

### K8sTaskOptions

```go
type K8sTaskOptions struct {
    // Scheduling
    NodeSelector      map[string]string
    Tolerations       []K8sToleration
    Affinity          *K8sAffinity
    PriorityClassName string

    // Resources
    Resources K8sResources
    GPU       int

    // Security
    ServiceAccount  string
    SecurityContext *K8sSecurityContext

    // Networking
    HostNetwork bool
    DNSPolicy   string

    // Storage
    Volumes []K8sVolume

    // Metadata
    Labels      map[string]string
    Annotations map[string]string
    Namespace   string
}
```

### K8sResources

```go
type K8sResources struct {
    RequestCPU    string  // e.g., "500m", "2"
    RequestMemory string  // e.g., "512Mi", "4Gi"
    LimitCPU      string
    LimitMemory   string
    CPU           string  // Shorthand: sets both request and limit
    Memory        string  // Shorthand: sets both request and limit
}
```

### K8sToleration

```go
type K8sToleration struct {
    Key      string
    Operator string  // "Exists" or "Equal"
    Value    string
    Effect   string  // "NoSchedule", "PreferNoSchedule", "NoExecute"
}
```

### K8sSecurityContext

```go
type K8sSecurityContext struct {
    RunAsUser              *int64
    RunAsGroup             *int64
    RunAsNonRoot           bool
    Privileged             bool
    ReadOnlyRootFilesystem bool
    AddCapabilities        []string
    DropCapabilities       []string
}
```

### K8sVolume

```go
type K8sVolume struct {
    Name      string
    MountPath string
    ConfigMap *K8sConfigMapVolume  // { Name string }
    Secret    *K8sSecretVolume     // { Name string }
    EmptyDir  *K8sEmptyDirVolume   // { Medium, SizeLimit string }
    HostPath  *K8sHostPathVolume   // { Path, Type string }
    PVC       *K8sPVCVolume        // { ClaimName string }
}
```

---

## Target Interface

For implementing custom execution targets.

### Target

```go
type Target interface {
    RunTask(ctx context.Context, task TaskSpec) Result
}
```

The only required method. Everything else is optional.

### Optional Capabilities

```go
// Setup/teardown around pipeline execution
type Lifecycle interface {
    Setup(ctx context.Context) error
    Teardown(ctx context.Context) error
}

// Secret resolution
type Secrets interface {
    ResolveSecret(ctx context.Context, name string) (string, error)
}

// Volume and artifact management
type Storage interface {
    CreateVolume(ctx context.Context, name string, opts VolumeOptions) (Volume, error)
    ArtifactPath(taskName, artifactName string) string
    CopyArtifact(ctx context.Context, src, dst string) error
}

// Service container management
type Services interface {
    StartServices(ctx context.Context, taskName string, services []ServiceSpec) (interface{}, error)
    StopServices(ctx context.Context, networkInfo interface{}) error
}
```

### Capability Checking

```go
HasLifecycle(t Target) bool
HasSecrets(t Target) bool
HasStorage(t Target) bool
HasServices(t Target) bool

AsLifecycle(t Target) (Lifecycle, bool)
AsSecrets(t Target) (Secrets, bool)
AsStorage(t Target) (Storage, bool)
AsServices(t Target) (Services, bool)
```

---

## Language Presets

### Go Preset

```go
s.Go().Test()                    // go test ./...
s.Go().Lint()                    // go vet ./...
s.Go().Build(output string)      // go build -o <output>
GoInputs() []string              // ["**/*.go", "go.mod", "go.sum"]
```
