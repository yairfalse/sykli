# Sykli Rust SDK - API Reference

Complete API documentation for the Sykli Rust SDK.

## Table of Contents

- [Pipeline](#pipeline)
- [Task](#task)
- [Template](#template)
- [Resources](#resources)
- [Composition](#composition)
- [Conditions](#conditions)
- [Secrets](#secrets)
- [Kubernetes](#kubernetes)
- [Language Presets](#language-presets)

---

## Pipeline

### new

```rust
fn Pipeline::new() -> Pipeline
```

Creates a new pipeline.

**Example:**
```rust
let mut p = Pipeline::new();
```

### task

```rust
fn task(&mut self, name: &str) -> Task<'_>
```

Creates a new task. Panics if name is empty.

### template

```rust
fn template(&mut self, name: &str) -> Template
```

Creates a reusable task template.

### dir

```rust
fn dir(&self, path: &str) -> Directory
```

Creates a directory resource for mounting into containers.

### cache

```rust
fn cache(&self, name: &str) -> CacheVolume
```

Creates a named cache volume for persisting data between runs.

### emit

```rust
fn emit(&self)
```

Outputs the pipeline as JSON if `--emit` flag is present. Call this at the end of your pipeline.

### emit_to

```rust
fn emit_to<W: Write>(&self, writer: W) -> io::Result<()>
```

Writes the pipeline JSON to the given writer.

---

## Task

### run

```rust
fn run(self, cmd: &str) -> Self
```

Sets the command for this task. **Required.**

### container

```rust
fn container(self, image: &str) -> Self
```

Sets the container image for this task.

### mount

```rust
fn mount(self, dir: &Directory, path: &str) -> Self
```

Mounts a directory into the container. Path must be absolute.

### mount_cache

```rust
fn mount_cache(self, cache: &CacheVolume, path: &str) -> Self
```

Mounts a cache volume into the container.

### mount_cwd

```rust
fn mount_cwd(self) -> Self
```

Convenience method: mounts current directory to `/work` and sets workdir.

### mount_cwd_at

```rust
fn mount_cwd_at(self, path: &str) -> Self
```

Mounts current directory to a custom path and sets workdir.

### workdir

```rust
fn workdir(self, path: &str) -> Self
```

Sets the working directory inside the container.

### env

```rust
fn env(self, key: &str, value: &str) -> Self
```

Sets an environment variable.

### inputs

```rust
fn inputs(self, patterns: &[&str]) -> Self
```

Sets input file patterns for caching. Supports glob patterns (`**/*.rs`).

### output

```rust
fn output(self, name: &str, path: &str) -> Self
```

Declares a named output artifact.

### outputs

```rust
fn outputs(self, paths: &[&str]) -> Self
```

Declares multiple output artifacts with auto-generated names.

### input_from

```rust
fn input_from(self, from_task: &str, output_name: &str, dest_path: &str) -> Self
```

Consumes an artifact from another task's output. Automatically adds dependency.

### after

```rust
fn after(self, tasks: &[&str]) -> Self
```

Sets dependencies - this task runs after the named tasks.

### after_one

```rust
fn after_one(self, task: &str) -> Self
```

Convenience for single dependency.

### after_group

```rust
fn after_group(self, group: &TaskGroup) -> Self
```

Depends on all tasks in the given group.

### from

```rust
fn from(self, tmpl: &Template) -> Self
```

Applies a template's configuration. Task settings override template settings.

### when

```rust
fn when(self, condition: &str) -> Self
```

Sets a string condition for when this task should run.

### when_cond

```rust
fn when_cond(self, condition: Condition) -> Self
```

Sets a type-safe condition (compile-time checked).

### secret

```rust
fn secret(self, name: &str) -> Self
```

Declares that this task requires a secret.

### secrets

```rust
fn secrets(self, names: &[&str]) -> Self
```

Declares multiple required secrets.

### secret_from

```rust
fn secret_from(self, name: &str, ref_: SecretRef) -> Self
```

Declares a typed secret reference with explicit source.

### service

```rust
fn service(self, image: &str, name: &str) -> Self
```

Adds a service container (database, cache) that runs alongside this task.

### matrix

```rust
fn matrix(self, key: &str, values: &[&str]) -> Self
```

Adds a matrix dimension. Creates task variants for each value.

### retry

```rust
fn retry(self, n: u32) -> Self
```

Sets the number of retry attempts on failure.

### timeout

```rust
fn timeout(self, seconds: u32) -> Self
```

Sets the task timeout in seconds.

### target

```rust
fn target(self, name: &str) -> Self
```

Sets the target for this specific task, overriding pipeline default.

### k8s

```rust
fn k8s(self, opts: K8sOptions) -> Self
```

Adds Kubernetes-specific options.

### k8s_raw

```rust
fn k8s_raw(self, json: &str) -> Self
```

Adds raw Kubernetes JSON for advanced options not covered by the minimal API.

### name

```rust
fn name(&self) -> String
```

Returns the task's name (for use in dependencies).

---

## Template

Templates provide reusable task configuration.

### container

```rust
fn container(mut self, image: &str) -> Self
```

### workdir

```rust
fn workdir(mut self, path: &str) -> Self
```

### env

```rust
fn env(mut self, key: &str, value: &str) -> Self
```

### mount_dir

```rust
fn mount_dir(mut self, dir: &Directory, path: &str) -> Self
```

### mount_cache

```rust
fn mount_cache(mut self, cache: &CacheVolume, path: &str) -> Self
```

---

## Resources

### Directory

```rust
pub struct Directory { /* ... */ }
```

Represents a host directory.

**Methods:**
- `glob(patterns: &[&str])` - Filter by glob patterns
- `id() -> String` - Returns unique identifier

### CacheVolume

```rust
pub struct CacheVolume { /* ... */ }
```

Represents a named persistent cache.

**Methods:**
- `id() -> String` - Returns cache name

---

## Composition

### parallel

```rust
fn parallel(&mut self, name: &str, tasks: Vec<Task<'_>>) -> TaskGroup
```

Creates a group of tasks that run concurrently.

### chain

```rust
fn chain(&mut self, items: Vec<ChainItem<'_>>)
```

Creates a sequential dependency chain.

### matrix

```rust
fn matrix<F>(&mut self, name: &str, values: &[&str], generator: F) -> TaskGroup
where F: FnMut(&str) -> Task<'_>
```

Creates tasks for each value using a generator function.

### TaskGroup

```rust
pub struct TaskGroup { /* ... */ }
```

A group of tasks created by `parallel()` or `matrix()`.

**Methods:**
- `after(deps: &[&str])` - Make all tasks depend on given deps
- `task_names() -> Vec<String>` - Get names of all tasks in group

---

## Conditions

### String Conditions

```rust
task.when("branch == 'main'")
task.when("tag != ''")
task.when("event == 'push'")
task.when("ci == true")
```

### Type-Safe Conditions

```rust
// Builders
Condition::branch(pattern: &str) -> Condition
Condition::tag(pattern: &str) -> Condition
Condition::has_tag() -> Condition
Condition::event(event_type: &str) -> Condition
Condition::in_ci() -> Condition
Condition::negate(c: Condition) -> Condition

// Combinators
condition.or(other: Condition) -> Condition
condition.and(other: Condition) -> Condition
```

**Examples:**
```rust
.when_cond(Condition::branch("main"))
.when_cond(Condition::tag("v*"))
.when_cond(Condition::branch("main").or(Condition::tag("v*")))
.when_cond(Condition::negate(Condition::branch("wip/*")).and(Condition::event("push")))
```

---

## Secrets

### from_env

```rust
SecretRef::from_env(env_var: &str) -> SecretRef
```

Reads secret from environment variable.

### from_file

```rust
SecretRef::from_file(path: &str) -> SecretRef
```

Reads secret from file.

### from_vault

```rust
SecretRef::from_vault(path: &str) -> SecretRef
```

Reads secret from HashiCorp Vault. Path format: `"path/to/secret#field"`.

---

## Kubernetes

### K8sOptions

```rust
pub struct K8sOptions {
    pub memory: Option<String>,  // e.g., "4Gi", "512Mi"
    pub cpu: Option<String>,     // e.g., "2", "500m"
    pub gpu: Option<u32>,        // NVIDIA GPU count
}
```

**Builder pattern:**
```rust
K8sOptions::default()
    .memory("4Gi")
    .cpu("2")
    .gpu(1)
```

### k8s_raw

For advanced options not covered by the minimal API (tolerations, affinity, security contexts), use raw JSON:

```rust
task.k8s_raw(r#"{"nodeSelector": {"gpu": "true"}, "tolerations": [{"key": "gpu", "effect": "NoSchedule"}]}"#)
```

---

## Language Presets

### Rust Preset

```rust
p.rust().test()                    // cargo test
p.rust().lint()                    // cargo clippy (or cargo check)
p.rust().build(output: &str)       // cargo build --release
RustPreset::inputs()               // ["**/*.rs", "Cargo.toml", "Cargo.lock"]
```

**Example:**
```rust
let mut p = Pipeline::new();
let src = p.dir(".");

p.rust().test()
    .container("rust:1.75")
    .mount(&src, "/src")
    .workdir("/src");

p.rust().build("target/release/app")
    .container("rust:1.75")
    .mount(&src, "/src")
    .workdir("/src")
    .after(&["test"]);

p.emit();
```
