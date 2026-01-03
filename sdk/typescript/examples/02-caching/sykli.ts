/**
 * Example 02: Input-Based Caching
 *
 * This example demonstrates:
 * - Input patterns for cache keys
 * - Skip execution when inputs unchanged
 * - Multiple input sources
 *
 * Run with: npx ts-node --esm sykli.ts --emit | sykli run -
 */

import { Pipeline, tsInputs } from 'sykli';

const p = new Pipeline();

// Test task with TypeScript inputs
// Only re-runs when .ts/.tsx files or package.json change
p.task('test')
  .run('npm test')
  .inputs(...tsInputs()); // **/*.ts, **/*.tsx, etc.

// Type checking with specific inputs
p.task('typecheck')
  .run('npx tsc --noEmit')
  .inputs('**/*.ts', 'tsconfig.json');

// Lint with custom patterns
p.task('lint')
  .run('npm run lint')
  .inputs('**/*.ts', '**/*.tsx', '.eslintrc*');

// Build depends on all checks passing
p.task('build')
  .run('npm run build')
  .inputs('src/**/*', 'package.json', 'tsconfig.json')
  .after('test', 'typecheck', 'lint');

p.emit();

// With caching, unchanged inputs = instant skip:
//
// $ sykli run
// ✓ test (cached - inputs unchanged)
// ✓ typecheck (cached - inputs unchanged)
// ▶ lint (running...)
// ✓ lint
// ▶ build (running...)
// ✓ build
