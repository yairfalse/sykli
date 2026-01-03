/**
 * Example 04: DRY Configuration with Templates
 *
 * This example demonstrates:
 * - Creating reusable templates
 * - Applying templates to tasks
 * - Override template settings per-task
 *
 * Run with: npx ts-node --esm sykli.ts --emit | sykli run -
 */

import { Pipeline } from 'sykli';

const p = new Pipeline();

// Create shared resources
const src = p.dir('.');
const nodeModules = p.cache('node-modules');

// Template: Node.js task configuration
const nodeTemplate = p
  .template('node')
  .container('node:20-alpine')
  .mount(src, '/app')
  .mountCache(nodeModules, '/app/node_modules')
  .workdir('/app')
  .env('CI', 'true');

// All tasks use the template - no repetition
p.task('install').from(nodeTemplate).run('npm ci');

p.task('lint').from(nodeTemplate).run('npm run lint').after('install');

p.task('test').from(nodeTemplate).run('npm test').after('install');

p.task('typecheck').from(nodeTemplate).run('npm run typecheck').after('install');

// Build adds extra env var on top of template
p.task('build')
  .from(nodeTemplate)
  .env('NODE_ENV', 'production')
  .run('npm run build')
  .after('lint', 'test', 'typecheck');

// Different template for deployment
const deployTemplate = p
  .template('deploy')
  .container('alpine:3.18')
  .env('DEPLOY_ENV', 'production');

p.task('deploy')
  .from(deployTemplate)
  .run('./deploy.sh')
  .after('build');

p.emit();

// Templates eliminate repetition:
//
// WITHOUT templates:
//   task('test').container('node:20').mount(src, '/app')...
//   task('lint').container('node:20').mount(src, '/app')...
//   task('build').container('node:20').mount(src, '/app')...
//
// WITH templates:
//   task('test').from(nodeTemplate).run('npm test')
//   task('lint').from(nodeTemplate).run('npm run lint')
//   task('build').from(nodeTemplate).run('npm run build')
