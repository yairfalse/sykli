# ADR 018: TypeScript SDK

## Status
Proposed

## Context

Sykli has Go and Rust SDKs. TypeScript is conspicuously absent.

**Why this matters:**

1. **Ecosystem size**: npm has 2.5M+ packages. The JS/TS developer population dwarfs Go and Rust combined.

2. **Monorepo adoption**: The teams most likely to need Sykli (monorepos with multiple services) are often running TS frontends + Go/Python backends. They're currently using Turborepo or Nx.

3. **Competitive positioning**: Turborepo and Nx are TS-first. Without a TS SDK, Sykli is invisible to this audience.

4. **The "glue" opportunity**: A monorepo with `packages/web` (TS), `services/api` (Go), and `ml/` (Python) currently has three disconnected build systems. Sykli can unify them—but only if each language feels native.

## Decision

Build a TypeScript SDK with API parity to Go and Rust.

### API Design

```typescript
// sykli.ts
import { Pipeline } from '@sykli/sdk';

const p = new Pipeline();

// Resources
const src = p.dir('.');
const cache = p.cache('node-modules');

// Tasks with containers
p.task('install')
  .container('node:20-alpine')
  .mount(src, '/app')
  .mountCache(cache, '/app/node_modules')
  .workdir('/app')
  .run('npm ci');

p.task('lint')
  .after('install')
  .run('npm run lint');

p.task('test')
  .after('install')
  .run('npm test');

p.task('build')
  .after('lint', 'test')
  .run('npm run build')
  .outputs({ dist: './dist' });

// Node placement (new feature)
p.task('gpu-task')
  .requires('gpu', 'cuda')
  .run('python train.py');

p.emit();
```

### Execution Model

```bash
# Detection: core looks for sykli.ts, sykli.js, or sykli.mjs
$ sykli run

# Under the hood:
# 1. Detect sykli.ts
# 2. Run: npx tsx sykli.ts --emit
# 3. Parse JSON output
# 4. Execute task graph
```

**Why `npx tsx`?**
- Zero config TypeScript execution
- No compilation step needed
- Works with ESM and CJS
- Falls back to `node sykli.js` if no TS

### Package Distribution

```bash
npm install @sykli/sdk
# or
pnpm add @sykli/sdk
# or
bun add @sykli/sdk
```

**Package structure:**
```
@sykli/sdk/
├── src/
│   ├── index.ts       # Main exports
│   ├── pipeline.ts    # Pipeline class
│   ├── task.ts        # Task builder
│   ├── resources.ts   # Dir, Cache
│   └── emit.ts        # JSON serialization
├── dist/
│   ├── index.js       # ESM build
│   ├── index.cjs      # CJS build
│   └── index.d.ts     # Type definitions
└── package.json
```

### Type Safety

```typescript
// Compile-time validation
p.task('build')
  .after('test')      // ✓ string
  .after(['a', 'b'])  // ✓ string[]
  .after(123)         // ✗ Type error

// Runtime validation (at emit time)
p.task('deploy').after('nonexistent'); // Error: task 'nonexistent' not found

// Strict output types
interface TaskOutputs {
  [name: string]: string;  // output name → path
}
```

### Conditional Execution

```typescript
// Environment-based conditions
p.task('deploy')
  .when(env('GITHUB_REF').startsWith('refs/tags/'))
  .run('npm publish');

// Branch conditions
p.task('staging-deploy')
  .when(branch('main'))
  .run('./deploy-staging.sh');

// Compound conditions
p.task('release')
  .when(and(
    branch('main'),
    env('RELEASE').equals('true')
  ))
  .run('./release.sh');
```

### Templates (DRY)

```typescript
// Reusable configuration
const nodeTask = p.template()
  .container('node:20-alpine')
  .mount(src, '/app')
  .mountCache(cache, '/app/node_modules')
  .workdir('/app');

// Apply template
p.task('test').from(nodeTask).run('npm test');
p.task('lint').from(nodeTask).run('npm run lint');
p.task('build').from(nodeTask).run('npm run build');
```

### Matrix Builds

```typescript
p.task('test')
  .matrix({
    node: ['18', '20', '22'],
    os: ['linux', 'macos']
  })
  .container(`node:$\{matrix.node}`)
  .run('npm test');

// Expands to: test-18-linux, test-18-macos, test-20-linux, ...
```

### Cross-Language Dependencies

The killer feature for monorepos:

```typescript
// packages/web/sykli.ts
p.task('generate-types')
  .run('openapi-typescript ../api/openapi.yaml -o ./src/api.ts');

p.task('build')
  .after('generate-types')
  .run('npm run build');
```

```go
// services/api/sykli.go
s.Task("openapi").
    Run("go run ./cmd/openapi-gen").
    Outputs("./openapi.yaml")
```

**Root orchestrator:**
```typescript
// sykli.ts (root)
import { Pipeline } from '@sykli/sdk';

const p = new Pipeline();

// Import subprojects
p.import('./services/api');   // Runs api's sykli.go
p.import('./packages/web');   // Runs web's sykli.ts

// Cross-project dependency
p.task('web:generate-types')
  .after('api:openapi');      // TS task depends on Go task

p.emit();
```

## Consequences

### Positive

- **Massive reach**: Access to the largest developer ecosystem
- **Monorepo unification**: Single tool for TS + Go + Python + Rust projects
- **Competitive parity**: Direct alternative to Turborepo/Nx
- **Type safety**: Compile-time validation catches errors early
- **Familiar patterns**: Looks like every other TS library

### Negative

- **Maintenance burden**: Third SDK to maintain
- **Node.js dependency**: Adds runtime requirement for TS projects
- **Ecosystem expectations**: TS users expect VS Code integration, LSP, etc.

### Neutral

- Same JSON contract means core doesn't change
- Testing infrastructure can be shared

## Implementation Plan

### Phase 1: Core SDK (Week 1)
- [ ] Pipeline, Task, Resources classes
- [ ] JSON emission matching Go/Rust exactly
- [ ] npm package setup (@sykli/sdk)
- [ ] Basic tests

### Phase 2: Feature Parity (Week 2)
- [ ] Templates
- [ ] Matrix expansion
- [ ] Conditions (when)
- [ ] Secrets
- [ ] Services
- [ ] K8s options

### Phase 3: Detection & Integration (Week 3)
- [ ] Core detector for sykli.ts
- [ ] `npx tsx` execution
- [ ] Fallback to node for .js
- [ ] Error handling for missing dependencies

### Phase 4: Polish (Week 4)
- [ ] Documentation
- [ ] Examples (Next.js, Vite, monorepo)
- [ ] VS Code snippets
- [ ] npm publish automation

## Competitive Analysis

| Feature | Sykli | Turborepo | Nx |
|---------|-------|-----------|-----|
| Language-agnostic | ✓ | ✗ (JS/TS only) | ✗ (JS/TS focus) |
| Distributed execution | ✓ (Mesh) | ✗ | ✓ (Nx Cloud) |
| Container support | ✓ | ✗ | ✗ |
| K8s native | ✓ | ✗ | ✗ |
| Self-hosted cache | ✓ | ✗ | ✗ |
| Open core | ✓ | ✗ | Partial |

**Positioning**: "Turborepo for polyglot teams"

## Open Questions

1. **Bun support?** Bun is gaining traction. Should we support `bun run sykli.ts`?
   - *Tentative answer*: Yes, detect and prefer Bun if available.

2. **Deno support?** Less critical but growing.
   - *Tentative answer*: Not in v1, revisit based on demand.

3. **Package manager detection?** npm vs pnpm vs yarn vs bun
   - *Tentative answer*: Detect from lockfile, use for cache keys.

4. **Workspace-aware?** Should SDK understand npm/pnpm workspaces?
   - *Tentative answer*: Yes, `p.workspace()` helper for monorepos.

## References

- [Turborepo](https://turbo.build/repo) - The incumbent
- [Nx](https://nx.dev/) - Enterprise alternative
- [tsx](https://github.com/privatenumber/tsx) - TypeScript execution
- [ADR-005](./005-sdk-api.md) - Original SDK API design
