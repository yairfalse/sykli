/**
 * Example 01: Basic Tasks and Dependencies
 *
 * This example demonstrates:
 * - Creating tasks with run commands
 * - Setting up dependencies between tasks
 * - Emitting the pipeline JSON
 *
 * Run with: npx ts-node --esm sykli.ts --emit | sykli run -
 */

import { Pipeline } from 'sykli';

const p = new Pipeline();

// Define tasks - these run in parallel by default
p.task('lint').run('npm run lint');
p.task('test').run('npm test');

// Build depends on both lint and test
p.task('build').run('npm run build').after('lint', 'test');

// Deploy depends on build
p.task('deploy').run('./deploy.sh').after('build');

// Emit JSON if --emit flag is present
p.emit();

// Resulting execution order:
//
// lint  ──┐
//         ├──▶  build  ──▶  deploy
// test  ──┘
