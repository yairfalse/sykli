/**
 * Example 03: Container Execution
 *
 * This example demonstrates:
 * - Running tasks in containers
 * - Mounting source code and caches
 * - Environment variables
 * - Service containers (databases, etc.)
 *
 * Run with: npx ts-node --esm sykli.ts --emit | sykli run -
 */

import { Pipeline } from 'sykli';

const p = new Pipeline();

// Create resources
const src = p.dir('.');
const nodeModules = p.cache('node-modules');

// Run tests in Node container
p.task('test')
  .container('node:20')
  .mount(src, '/app')
  .mountCache(nodeModules, '/app/node_modules')
  .workdir('/app')
  .run('npm ci && npm test');

// Or use the convenience method
p.task('lint')
  .container('node:20')
  .mountCwd() // mounts . to /work and sets workdir
  .mountCache(nodeModules, '/work/node_modules')
  .run('npm ci && npm run lint');

// Build with environment variables
p.task('build')
  .container('node:20')
  .mountCwd()
  .mountCache(nodeModules, '/work/node_modules')
  .env('NODE_ENV', 'production')
  .run('npm ci && npm run build')
  .after('test', 'lint');

// Integration tests with service containers
p.task('integration')
  .container('node:20')
  .mountCwd()
  .service('postgres:15', 'db')
  .service('redis:7', 'cache')
  .env('DATABASE_URL', 'postgres://postgres:postgres@db:5432/test')
  .env('REDIS_URL', 'redis://cache:6379')
  .run('npm run test:integration')
  .after('build');

p.emit();

// Container execution isolates each task:
//
// ┌─────────────────────────────────────────────────┐
// │ node:20 container                               │
// │                                                 │
// │  /work (source mounted)                         │
// │  /work/node_modules (cache volume)              │
// │                                                 │
// │  + services: postgres:15, redis:7               │
// └─────────────────────────────────────────────────┘
