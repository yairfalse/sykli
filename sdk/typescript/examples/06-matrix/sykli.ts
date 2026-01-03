/**
 * Example 06: Matrix Builds and Advanced Features
 *
 * This example demonstrates:
 * - Matrix builds across multiple dimensions
 * - Dynamic pipeline generation
 * - Kubernetes options
 * - Secrets management
 * - Retry and timeout
 *
 * Run with: npx ts-node --esm sykli.ts --emit | sykli run -
 */

import { Pipeline, branch, tag, fromEnv, fromVault } from 'sykli';

const p = new Pipeline();

// === MATRIX BUILDS ===
// Test across Node versions
const nodeVersions = ['18', '20', '22'];

const nodeTests = p.matrix('node-tests', nodeVersions, (version) =>
  p.task(`test-node-${version}`)
    .container(`node:${version}`)
    .mountCwd()
    .run('npm ci && npm test')
);

// Matrix with map: different browsers
const browsers: Record<string, string> = {
  chrome: 'mcr.microsoft.com/playwright:latest',
  firefox: 'mcr.microsoft.com/playwright:latest',
  webkit: 'mcr.microsoft.com/playwright:latest',
};

const e2eTests = p.matrixMap('e2e-tests', browsers, (browser, image) =>
  p.task(`e2e-${browser}`)
    .container(image)
    .mountCwd()
    .env('BROWSER', browser)
    .run('npx playwright test')
    .afterGroup(nodeTests)
);

// === DYNAMIC GENERATION ===
// Generate tasks from data (TypeScript power!)
const services = ['api', 'web', 'worker'];

for (const svc of services) {
  p.task(`build-${svc}`)
    .container('node:20')
    .mountCwd()
    .run(`npm run build:${svc}`)
    .afterGroup(nodeTests);
}

// === KUBERNETES OPTIONS ===
p.task('gpu-inference')
  .container('pytorch/pytorch:2.0')
  .mountCwd()
  .run('python inference.py')
  .k8s({
    gpu: 1,
    resources: {
      requestMemory: '8Gi',
      limitMemory: '16Gi',
    },
    nodeSelector: { 'gpu-type': 'nvidia-a100' },
    tolerations: [
      { key: 'nvidia.com/gpu', operator: 'Exists', effect: 'NoSchedule' },
    ],
  })
  .afterGroup(nodeTests);

// === SECRETS ===
p.task('deploy')
  .container('alpine:3.18')
  .run('./deploy.sh')
  .secret('DEPLOY_TOKEN') // Simple secret
  .secretFrom('AWS_KEY', fromEnv('AWS_ACCESS_KEY_ID'))
  .secretFrom('DB_PASS', fromVault('secret/data/prod/db'))
  .whenCond(branch('main'))
  .afterGroup(e2eTests);

// === RETRY & TIMEOUT ===
p.task('flaky-integration')
  .container('node:20')
  .mountCwd()
  .run('npm run test:integration')
  .retry(3) // Retry up to 3 times
  .timeout(600) // 10 minute timeout
  .afterGroup(nodeTests);

// === PUBLISH ===
p.task('publish')
  .run('npm publish')
  .secret('NPM_TOKEN')
  .whenCond(tag('v*'))
  .afterGroup(e2eTests);

p.emit();

// Matrix expansion:
//
// test-node-18 ─┐
// test-node-20 ─┼─▶ e2e-chrome  ─┐
// test-node-22 ─┘   e2e-firefox ─┼─▶ deploy (on main)
//                   e2e-webkit  ─┘   publish (on v*)
