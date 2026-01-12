# Sykli TypeScript SDK - API Reference

Complete API documentation for the Sykli TypeScript SDK.

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

### constructor

```typescript
new Pipeline()
```

Creates a new pipeline.

**Example:**
```typescript
const p = new Pipeline();
```

### task

```typescript
task(name: string): Task
```

Creates a new task. Throws if name is empty or duplicate.

### template

```typescript
template(name: string): Template
```

Creates a reusable task template.

### dir

```typescript
dir(path: string): Directory
```

Creates a directory resource for mounting into containers.

### cache

```typescript
cache(name: string): CacheVolume
```

Creates a named cache volume for persisting data between runs.

### emit

```typescript
emit(): void
```

Outputs the pipeline as JSON if `--emit` flag is present. Call this at the end of your pipeline.

### emitTo

```typescript
emitTo(writer: { write(s: string): void }): void
```

Writes the pipeline JSON to the given writer.

### toJSON

```typescript
toJSON(): PipelineJSON
```

Returns the pipeline as a JSON-serializable object.

---

## Task

### run

```typescript
run(command: string): this
```

Sets the command for this task. **Required.**

### container

```typescript
container(image: string): this
```

Sets the container image for this task.

### mount

```typescript
mount(dir: Directory, path: string): this
```

Mounts a directory into the container. Path must be absolute.

### mountCache

```typescript
mountCache(cache: CacheVolume, path: string): this
```

Mounts a cache volume into the container.

### mountCwd

```typescript
mountCwd(): this
```

Convenience method: mounts current directory to `/work` and sets workdir.

### mountCwdAt

```typescript
mountCwdAt(containerPath: string): this
```

Mounts current directory to a custom path and sets workdir.

### workdir

```typescript
workdir(path: string): this
```

Sets the working directory inside the container.

### env

```typescript
env(key: string, value: string): this
```

Sets an environment variable.

### inputs

```typescript
inputs(...patterns: string[]): this
```

Sets input file patterns for caching. Supports glob patterns (`**/*.ts`).

### output

```typescript
output(name: string, path: string): this
```

Declares a named output artifact.

### outputs

```typescript
outputs(...paths: string[]): this
```

Declares multiple output artifacts with auto-generated names.

### inputFrom

```typescript
inputFrom(fromTask: string, outputName: string, destPath: string): this
```

Consumes an artifact from another task's output. Automatically adds dependency.

### after

```typescript
after(...tasks: string[]): this
```

Sets dependencies - this task runs after the named tasks.

### afterGroup

```typescript
afterGroup(group: TaskGroup): this
```

Depends on all tasks in the given group.

### from

```typescript
from(template: Template): this
```

Applies a template's configuration. Task settings override template settings.

### when

```typescript
when(condition: string): this
```

Sets a string condition for when this task should run.

### whenCond

```typescript
whenCond(condition: Condition): this
```

Sets a type-safe condition (compile-time checked).

### secret

```typescript
secret(name: string): this
```

Declares that this task requires a secret.

### secrets

```typescript
secrets(...names: string[]): this
```

Declares multiple required secrets.

### secretFrom

```typescript
secretFrom(name: string, ref: SecretRef): this
```

Declares a typed secret reference with explicit source.

### service

```typescript
service(image: string, name: string): this
```

Adds a service container (database, cache) that runs alongside this task.

### matrix

```typescript
matrix(key: string, ...values: string[]): this
```

Adds a matrix dimension. Creates task variants for each value.

### retry

```typescript
retry(n: number): this
```

Sets the number of retry attempts on failure.

### timeout

```typescript
timeout(seconds: number): this
```

Sets the task timeout in seconds.

### target

```typescript
target(name: string): this
```

Sets the target for this specific task, overriding pipeline default.

### k8s

```typescript
k8s(opts: K8sOptions): this
```

Adds Kubernetes-specific options.

### k8sRaw

```typescript
k8sRaw(json: string): this
```

Adds raw Kubernetes JSON for advanced options not covered by the minimal API.

### name

```typescript
get name(): string
```

Returns the task's name (for use in dependencies).

---

## Template

Templates provide reusable task configuration.

### container

```typescript
container(image: string): this
```

### workdir

```typescript
workdir(path: string): this
```

### env

```typescript
env(key: string, value: string): this
```

### mount

```typescript
mount(dir: Directory, path: string): this
```

### mountCache

```typescript
mountCache(cache: CacheVolume, path: string): this
```

---

## Resources

### Directory

```typescript
class Directory {
  glob(...patterns: string[]): this
  id(): string
}
```

Represents a host directory.

### CacheVolume

```typescript
class CacheVolume {
  id(): string
}
```

Represents a named persistent cache.

---

## Composition

### parallel

```typescript
parallel(name: string, ...tasks: Task[]): TaskGroup
```

Creates a group of tasks that run concurrently.

### chain

```typescript
chain(...items: (Task | TaskGroup)[]): void
```

Creates a sequential dependency chain.

### matrix

```typescript
matrix(name: string, values: string[], generator: (value: string) => Task): TaskGroup
```

Creates tasks for each value using a generator function.

### TaskGroup

```typescript
class TaskGroup {
  after(...deps: string[]): this
  taskNames(): string[]
}
```

A group of tasks created by `parallel()` or `matrix()`.

---

## Conditions

### String Conditions

```typescript
task.when("branch == 'main'")
task.when("tag != ''")
task.when("event == 'push'")
task.when("ci == true")
```

### Type-Safe Conditions

```typescript
// Builders
branch(pattern: string): Condition
tag(pattern: string): Condition
hasTag(): Condition
event(eventType: string): Condition
inCI(): Condition
not(c: Condition): Condition

// Combinators
condition.or(other: Condition): Condition
condition.and(other: Condition): Condition
```

**Examples:**
```typescript
.whenCond(branch("main"))
.whenCond(tag("v*"))
.whenCond(branch("main").or(tag("v*")))
.whenCond(not(branch("wip/*")).and(event("push")))
```

---

## Secrets

### fromEnv

```typescript
fromEnv(envVar: string): SecretRef
```

Reads secret from environment variable.

### fromFile

```typescript
fromFile(path: string): SecretRef
```

Reads secret from file.

### fromVault

```typescript
fromVault(path: string): SecretRef
```

Reads secret from HashiCorp Vault. Path format: `"path/to/secret#field"`.

---

## Kubernetes

### K8sOptions

```typescript
interface K8sOptions {
  memory?: string;  // e.g., "4Gi", "512Mi"
  cpu?: string;     // e.g., "2", "500m"
  gpu?: number;     // NVIDIA GPU count
}
```

**Example:**
```typescript
task.k8s({ memory: "4Gi", cpu: "2", gpu: 1 })
```

### k8sRaw

For advanced options not covered by the minimal API (tolerations, affinity, security contexts), use raw JSON:

```typescript
task.k8sRaw('{"nodeSelector": {"gpu": "true"}, "tolerations": [{"key": "gpu", "effect": "NoSchedule"}]}')
```

---

## Language Presets

### Node.js Preset

```typescript
p.node().test()                    // npm test
p.node().lint()                    // npm run lint
p.node().build()                   // npm run build
nodeInputs()                       // ["**/*.ts", "**/*.js", "package.json", "package-lock.json"]
```

### TypeScript Preset

```typescript
p.typescript().test()              // npm test
p.typescript().lint()              // npm run lint
p.typescript().build()             // npm run build
p.typescript().typecheck()         // npx tsc --noEmit
tsInputs()                         // ["**/*.ts", "**/*.tsx", "tsconfig.json", "package.json"]
```

**Example:**
```typescript
const p = new Pipeline();
const src = p.dir(".");
const nodeModules = p.cache("node-modules");

p.node().test()
  .container("node:20")
  .mount(src, "/app")
  .mountCache(nodeModules, "/app/node_modules")
  .workdir("/app");

p.node().build()
  .container("node:20")
  .mount(src, "/app")
  .mountCache(nodeModules, "/app/node_modules")
  .workdir("/app")
  .after("test");

p.emit();
```
