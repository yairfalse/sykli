/**
 * Example 05: Pipeline Composition
 *
 * This example demonstrates:
 * - Parallel task groups
 * - Sequential chains
 * - Artifact passing between tasks (InputFrom)
 * - Conditional execution (When)
 *
 * Run with: npx ts-node --esm sykli.ts --emit | sykli run -
 */

import { Pipeline, branch, tag, hasTag } from 'sykli';

const p = new Pipeline();

// === PARALLEL GROUPS ===
// Tasks that can run concurrently
const lint = p.task('lint').run('npm run lint');
const test = p.task('test').run('npm test');
const typecheck = p.task('typecheck').run('npm run typecheck');

// Group them for easy dependency management
const checks = p.parallel('checks', [lint, test, typecheck]);

// === ARTIFACT PASSING ===
// Build produces artifacts that deploy consumes
p.task('build')
  .run('npm run build')
  .output('dist', './dist') // Declare output artifact
  .afterGroup(checks);

p.task('package')
  .run('tar -czf app.tar.gz dist/')
  .inputFrom('build', 'dist', './dist') // Consume build's output
  .output('tarball', './app.tar.gz');

// === SEQUENTIAL CHAINS ===
// Chain ensures strict ordering
const deploy = p.task('deploy-staging').run('./deploy.sh staging');
const smoke = p.task('smoke-test').run('./smoke-test.sh');
const promote = p.task('deploy-prod').run('./deploy.sh prod');

p.chain(p.task('package'), deploy, smoke, promote);

// === CONDITIONAL EXECUTION ===
// Only deploy to prod on main branch
p.task('deploy-prod').whenCond(branch('main'));

// Publish only on tags
p.task('publish')
  .run('npm publish')
  .whenCond(hasTag())
  .after('build');

// Release only on v* tags
p.task('release')
  .run('gh release create')
  .whenCond(tag('v*'))
  .after('publish');

// Complex condition: main branch OR any tag
p.task('notify')
  .run('./notify.sh')
  .whenCond(branch('main').or(hasTag()))
  .after('build');

p.emit();

// Execution flow:
//
// lint      ─┐
// test      ─┼─▶ build ─▶ package ─▶ deploy-staging ─▶ smoke ─▶ deploy-prod
// typecheck ─┘      │
//                   └──▶ publish (on tag) ─▶ release (on v*)
