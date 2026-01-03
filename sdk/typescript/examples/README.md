# Sykli TypeScript SDK Examples

Progressive examples from basic to advanced usage.

## Examples

| Example | Description |
|---------|-------------|
| [01-basic](./01-basic/) | Tasks, dependencies, and parallel execution |
| [02-caching](./02-caching/) | Input-based caching and conditional execution |
| [03-containers](./03-containers/) | Container execution with mounts and caches |
| [04-templates](./04-templates/) | DRY configuration with templates |
| [05-composition](./05-composition/) | Parallel groups, chains, and artifact passing |
| [06-matrix](./06-matrix/) | Matrix builds, K8s options, and secrets |

## Running Examples

Each example is a standalone TypeScript file. To run:

```bash
cd 01-basic
npx ts-node --esm sykli.ts --emit | sykli run -
```

Or with sykli directly:

```bash
sykli run --file examples/01-basic/sykli.ts
```

## Learning Path

Start with **01-basic** and progress through each example:

1. **01-basic**: Understand task definition and dependencies
2. **02-caching**: Learn how to skip unchanged work
3. **03-containers**: Isolate tasks in containers
4. **04-templates**: Eliminate repetition with templates
5. **05-composition**: Build complex pipelines with combinators
6. **06-matrix**: Test across multiple configurations

Each example builds on concepts from previous ones.

## Key TypeScript Benefits

The TypeScript SDK leverages the type system:

```typescript
// Type-safe conditions
import { branch, tag, hasTag } from 'sykli';

task.whenCond(branch('main').or(hasTag()));

// Type-safe K8s options
task.k8s({
  resources: { requestMemory: '4Gi' },
  nodeSelector: { 'gpu-type': 'nvidia' },
});

// Autocomplete for all methods
p.task('build')
  .container('node:20')  // IDE shows all Task methods
  .mountCwd()
  .run('npm build');
```
