# Sykli TypeScript SDK

CI pipelines defined in TypeScript instead of YAML.

```typescript
import { Pipeline } from 'sykli';

const p = new Pipeline();
p.task('test').run('npm test');
p.task('build').run('npm run build').after('test');
p.emit();
```

## Installation

```bash
npm install sykli
```

## Quick Start

Create `sykli.ts`:

```typescript
import { Pipeline } from 'sykli';

const p = new Pipeline();

// Tasks run in parallel by default
p.task('lint').run('npm run lint');
p.task('test').run('npm test');

// Dependencies create execution order
p.task('build')
  .run('npm run build')
  .after('lint', 'test');

p.emit();
```

Run it:

```bash
npx ts-node --esm sykli.ts --emit | sykli run -
```

## Core Concepts

### Tasks

```typescript
p.task('name')
  .run('command')           // Command to execute
  .after('dep1', 'dep2')    // Dependencies
  .inputs('**/*.ts')        // Cache inputs
  .output('dist', './dist') // Named outputs
  .timeout(300)             // Timeout in seconds
  .retry(3);                // Retry count
```

### Dependencies

```typescript
// Single dependency
p.task('build').after('test');

// Multiple dependencies (parallel execution)
p.task('deploy').after('lint', 'test', 'build');

// After a task group
p.task('deploy').afterGroup(testsGroup);
```

### Input Caching

```typescript
import { tsInputs, nodeInputs } from 'sykli';

// TypeScript project inputs
p.task('build').inputs(...tsInputs());

// Custom patterns
p.task('test').inputs('**/*.ts', 'package.json');
```

## Containers

```typescript
const src = p.dir('.');
const nodeModules = p.cache('node-modules');

p.task('test')
  .container('node:20')
  .mount(src, '/app')
  .mountCache(nodeModules, '/app/node_modules')
  .workdir('/app')
  .run('npm test');

// Shorthand for common pattern
p.task('build')
  .container('node:20')
  .mountCwd()  // Mounts . to /work, sets workdir
  .run('npm run build');
```

### Service Containers

```typescript
p.task('integration')
  .container('node:20')
  .mountCwd()
  .service('postgres:15', 'db')
  .service('redis:7', 'cache')
  .env('DATABASE_URL', 'postgres://postgres@db:5432/test')
  .run('npm run test:integration');
```

## Templates

```typescript
const nodeTemplate = p.template('node')
  .container('node:20')
  .mount(p.dir('.'), '/app')
  .workdir('/app')
  .env('CI', 'true');

// Apply to tasks
p.task('test').from(nodeTemplate).run('npm test');
p.task('lint').from(nodeTemplate).run('npm run lint');
p.task('build').from(nodeTemplate).run('npm run build');
```

## Composition

### Parallel Groups

```typescript
const lint = p.task('lint').run('npm run lint');
const test = p.task('test').run('npm test');
const typecheck = p.task('typecheck').run('tsc --noEmit');

const checks = p.parallel('checks', [lint, test, typecheck]);

p.task('build').afterGroup(checks);
```

### Chains

```typescript
const build = p.task('build').run('npm run build');
const deploy = p.task('deploy').run('./deploy.sh');
const smoke = p.task('smoke-test').run('./smoke.sh');

p.chain(build, deploy, smoke);
// build -> deploy -> smoke-test
```

### Artifact Passing

```typescript
p.task('build')
  .run('npm run build')
  .output('dist', './dist');

p.task('deploy')
  .inputFrom('build', 'dist', './dist')
  .run('./deploy.sh');
```

## Conditions

```typescript
import { branch, tag, hasTag, event, inCI, not } from 'sykli';

// Branch matching
p.task('deploy').whenCond(branch('main'));
p.task('preview').whenCond(branch('feature/*'));

// Tag matching
p.task('release').whenCond(tag('v*'));
p.task('publish').whenCond(hasTag());

// Combined conditions
p.task('notify').whenCond(
  branch('main').or(hasTag())
);

// String conditions still work
p.task('deploy').when("branch == 'main'");
```

## Matrix Builds

```typescript
// Array matrix
const versions = ['18', '20', '22'];

const tests = p.matrix('node-tests', versions, (v) =>
  p.task(`test-node-${v}`)
    .container(`node:${v}`)
    .run('npm test')
);

// Map matrix
const browsers = { chrome: 'chromium', firefox: 'firefox' };

const e2e = p.matrixMap('e2e', browsers, (name, engine) =>
  p.task(`e2e-${name}`)
    .env('BROWSER', engine)
    .run('npx playwright test')
);
```

### Dynamic Generation

```typescript
// Use full TypeScript power
const services = ['api', 'web', 'worker'];

for (const svc of services) {
  p.task(`build-${svc}`)
    .run(`npm run build:${svc}`)
    .after('test');
}
```

## Secrets

```typescript
import { fromEnv, fromFile, fromVault } from 'sykli';

// Simple secrets
p.task('deploy').secret('DEPLOY_TOKEN');

// Multiple secrets
p.task('release').secrets('NPM_TOKEN', 'GITHUB_TOKEN');

// Typed secret references
p.task('db-migrate')
  .secretFrom('DB_PASS', fromEnv('DATABASE_PASSWORD'))
  .secretFrom('API_KEY', fromVault('secret/data/prod/api'))
  .secretFrom('CERT', fromFile('/run/secrets/cert.pem'));
```

## Kubernetes Options

```typescript
p.task('ml-train')
  .container('pytorch/pytorch:2.0')
  .k8s({
    namespace: 'ml-jobs',
    resources: {
      requestCpu: '4',
      requestMemory: '16Gi',
      limitCpu: '8',
      limitMemory: '32Gi',
    },
    gpu: 1,
    nodeSelector: { 'gpu-type': 'nvidia-a100' },
    tolerations: [
      { key: 'nvidia.com/gpu', operator: 'Exists', effect: 'NoSchedule' },
    ],
    serviceAccount: 'ml-runner',
    securityContext: {
      runAsNonRoot: true,
      readOnlyRootFilesystem: true,
    },
  });
```

### K8s Types

```typescript
interface K8sOptions {
  namespace?: string;
  nodeSelector?: Record<string, string>;
  tolerations?: K8sToleration[];
  priorityClassName?: string;
  resources?: K8sResources;
  gpu?: number;
  serviceAccount?: string;
  securityContext?: K8sSecurityContext;
  hostNetwork?: boolean;
  dnsPolicy?: string;
  volumes?: K8sVolume[];
  labels?: Record<string, string>;
  annotations?: Record<string, string>;
}
```

## Complete Example

```typescript
import { Pipeline, branch, tag, tsInputs, fromEnv } from 'sykli';

const p = new Pipeline();

// Resources
const src = p.dir('.');
const nodeModules = p.cache('node-modules');

// Template for Node tasks
const node = p.template('node')
  .container('node:20-alpine')
  .mount(src, '/app')
  .mountCache(nodeModules, '/app/node_modules')
  .workdir('/app');

// Quality checks (parallel)
const lint = p.task('lint').from(node).run('npm run lint');
const test = p.task('test').from(node).run('npm test').inputs(...tsInputs());
const typecheck = p.task('typecheck').from(node).run('tsc --noEmit');
const checks = p.parallel('checks', [lint, test, typecheck]);

// Build with artifact output
p.task('build')
  .from(node)
  .run('npm run build')
  .output('dist', './dist')
  .afterGroup(checks);

// Integration with services
p.task('integration')
  .from(node)
  .service('postgres:15', 'db')
  .env('DATABASE_URL', 'postgres://postgres@db:5432/test')
  .run('npm run test:integration')
  .after('build');

// Deploy to staging (main only)
p.task('deploy-staging')
  .run('./deploy.sh staging')
  .secretFrom('TOKEN', fromEnv('DEPLOY_TOKEN'))
  .whenCond(branch('main'))
  .after('integration');

// Publish on tags
p.task('publish')
  .from(node)
  .run('npm publish')
  .secret('NPM_TOKEN')
  .whenCond(tag('v*'))
  .after('build');

p.emit();
```

## Examples

See the [examples](./examples/) directory:

| Example | Description |
|---------|-------------|
| [01-basic](./examples/01-basic/) | Tasks and dependencies |
| [02-caching](./examples/02-caching/) | Input-based caching |
| [03-containers](./examples/03-containers/) | Container execution |
| [04-templates](./examples/04-templates/) | Reusable templates |
| [05-composition](./examples/05-composition/) | Parallel, chain, artifacts |
| [06-matrix](./examples/06-matrix/) | Matrix builds and K8s |

## Validation

The SDK validates pipelines at emit time and fails fast with helpful errors:

```typescript
import { Pipeline, ValidationError } from 'sykli';

// Cycle detection
const p = new Pipeline();
p.task('a').run('echo a').after('b');
p.task('b').run('echo b').after('a');
p.toJSON(); // throws: "Dependency cycle detected: a → b → a"

// Typo suggestions (Jaro-Winkler similarity)
p.task('deploy').after('biuld'); // throws: "depends on unknown task 'biuld' (did you mean 'build'?)"

// Missing command
p.task('test'); // no .run()
p.toJSON(); // throws: "Task 'test' has no command (did you forget to call .run()?)"
```

### ValidationError

```typescript
class ValidationError extends Error {
  code: 'EMPTY_NAME' | 'DUPLICATE_TASK' | 'UNKNOWN_DEPENDENCY' | 'CYCLE_DETECTED' | 'MISSING_COMMAND';
  suggestion?: string;
}
```

## Dry-Run with explain()

Preview execution without running anything:

```typescript
const p = new Pipeline();
p.task('test').run('npm test');
p.task('build').run('npm build').after('test');
p.task('deploy').run('deploy.sh').after('build').whenCond(branch('main'));

console.log(p.explain({ branch: 'feature/foo' }));
```

Output:
```
Pipeline Execution Plan
=======================

1. test
   Command: npm test

2. build (after: test)
   Command: npm build

3. deploy (after: build) [SKIPPED: branch is 'feature/foo', not 'main']
   Command: deploy.sh
   Condition: branch == 'main'
```

## Pipeline-Level K8s Defaults

Set K8s defaults for all tasks:

```typescript
const p = new Pipeline({
  k8sDefaults: {
    namespace: 'ci-jobs',
    serviceAccount: 'ci-runner',
    resources: { requestMemory: '2Gi' },
  },
});

// All tasks inherit defaults, can override per-task
p.task('build').run('npm build').k8s({ resources: { requestMemory: '4Gi' } });
```

## API Reference

### Pipeline

| Method | Description |
|--------|-------------|
| `task(name)` | Create a task |
| `template(name)` | Create a reusable template |
| `dir(path)` | Create directory resource |
| `cache(name)` | Create cache volume |
| `parallel(name, tasks)` | Group tasks for parallel execution |
| `chain(...items)` | Create sequential chain |
| `matrix(name, values, fn)` | Generate tasks from array |
| `matrixMap(name, obj, fn)` | Generate tasks from object |
| `validate()` | Validate pipeline (called automatically) |
| `explain(ctx?)` | Dry-run visualization |
| `emit()` | Output JSON if --emit flag present |

### Task

| Method | Description |
|--------|-------------|
| `run(cmd)` | Set command |
| `from(template)` | Apply template |
| `container(image)` | Set container |
| `mount(dir, path)` | Mount directory |
| `mountCache(cache, path)` | Mount cache volume |
| `mountCwd()` | Mount . to /work |
| `workdir(path)` | Set working directory |
| `env(key, value)` | Set environment variable |
| `inputs(...patterns)` | Set cache input patterns |
| `output(name, path)` | Declare output artifact |
| `inputFrom(task, output, dest)` | Consume artifact |
| `after(...tasks)` | Set dependencies |
| `afterGroup(group)` | Depend on task group |
| `when(expr)` | String condition |
| `whenCond(cond)` | Type-safe condition |
| `secret(name)` | Require secret |
| `secretFrom(name, ref)` | Typed secret reference |
| `service(image, name)` | Add service container |
| `retry(n)` | Set retry count |
| `timeout(s)` | Set timeout |
| `k8s(options)` | Set K8s options |

### Conditions

| Function | Description |
|----------|-------------|
| `branch(pattern)` | Match branch |
| `tag(pattern)` | Match tag pattern |
| `hasTag()` | Any tag present |
| `event(type)` | Match CI event |
| `inCI()` | Running in CI |
| `not(cond)` | Negate condition |

Conditions can be combined:
```typescript
branch('main').or(hasTag())
branch('main').and(event('push'))
```

## License

MIT
