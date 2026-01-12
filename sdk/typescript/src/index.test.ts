/**
 * Sykli TypeScript SDK Tests
 *
 * Tests for validation, cycle detection, and core functionality.
 */

import { describe, it, expect } from 'vitest';
import {
  Pipeline,
  ValidationError,
  branch,
  tag,
  hasTag,
  not,
  fromEnv,
  fromVault,
  tsInputs,
} from './index.js';

// =============================================================================
// BASIC FUNCTIONALITY
// =============================================================================

describe('Pipeline', () => {
  describe('basic tasks', () => {
    it('creates a simple pipeline with one task', () => {
      const p = new Pipeline();
      p.task('test').run('npm test');

      const json = p.toJSON();
      expect(json.version).toBe('1');
      expect(json.tasks).toHaveLength(1);
      expect((json.tasks as any[])[0].name).toBe('test');
      expect((json.tasks as any[])[0].command).toBe('npm test');
    });

    it('creates tasks with dependencies', () => {
      const p = new Pipeline();
      p.task('lint').run('npm run lint');
      p.task('test').run('npm test');
      p.task('build').run('npm run build').after('lint', 'test');

      const json = p.toJSON();
      const buildTask = (json.tasks as any[]).find((t) => t.name === 'build');
      expect(buildTask.depends_on).toEqual(['lint', 'test']);
    });

    it('detects v2 features and sets version accordingly', () => {
      const p = new Pipeline();
      p.task('test').container('node:20').run('npm test');

      const json = p.toJSON();
      expect(json.version).toBe('2');
    });
  });

  describe('conditions', () => {
    it('supports branch conditions', () => {
      const p = new Pipeline();
      p.task('deploy').run('deploy.sh').whenCond(branch('main'));

      const json = p.toJSON();
      expect((json.tasks as any[])[0].when).toBe("branch == 'main'");
    });

    it('supports glob patterns in branch conditions', () => {
      const p = new Pipeline();
      p.task('preview').run('preview.sh').whenCond(branch('feature/*'));

      const json = p.toJSON();
      expect((json.tasks as any[])[0].when).toBe("branch matches 'feature/*'");
    });

    it('supports combined conditions', () => {
      const p = new Pipeline();
      p.task('release').run('release.sh').whenCond(branch('main').or(hasTag()));

      const json = p.toJSON();
      expect((json.tasks as any[])[0].when).toBe("(branch == 'main') || (tag != '')");
    });

    it('supports negated conditions', () => {
      const p = new Pipeline();
      p.task('test').run('test.sh').whenCond(not(branch('wip/*')));

      const json = p.toJSON();
      expect((json.tasks as any[])[0].when).toBe("!(branch matches 'wip/*')");
    });
  });

  describe('containers and resources', () => {
    it('creates directory and cache resources', () => {
      const p = new Pipeline();
      const src = p.dir('.');
      const cache = p.cache('node-modules');

      p.task('test')
        .container('node:20')
        .mount(src, '/app')
        .mountCache(cache, '/app/node_modules')
        .workdir('/app')
        .run('npm test');

      const json = p.toJSON();
      expect(json.version).toBe('2');
      expect(json.resources).toBeDefined();
      expect((json.resources as any)['src:.']).toEqual({ type: 'directory', path: '.' });
      expect((json.resources as any)['node-modules']).toEqual({ type: 'cache', name: 'node-modules' });
    });

    it('supports mountCwd convenience method', () => {
      const p = new Pipeline();
      p.task('test').container('node:20').mountCwd().run('npm test');

      const json = p.toJSON();
      const task = (json.tasks as any[])[0];
      expect(task.workdir).toBe('/work');
      expect(task.mounts).toContainEqual({
        resource: 'src:.',
        path: '/work',
        type: 'directory',
      });
    });
  });

  describe('secrets', () => {
    it('supports simple secrets', () => {
      const p = new Pipeline();
      p.task('deploy').run('deploy.sh').secrets('TOKEN', 'API_KEY');

      const json = p.toJSON();
      expect((json.tasks as any[])[0].secrets).toEqual(['TOKEN', 'API_KEY']);
    });

    it('supports typed secret references', () => {
      const p = new Pipeline();
      p.task('deploy')
        .run('deploy.sh')
        .secretFrom('DB_PASS', fromEnv('DATABASE_PASSWORD'))
        .secretFrom('API_KEY', fromVault('secret/data/api'));

      const json = p.toJSON();
      expect((json.tasks as any[])[0].secret_refs).toEqual([
        { name: 'DB_PASS', source: 'env', key: 'DATABASE_PASSWORD' },
        { name: 'API_KEY', source: 'vault', key: 'secret/data/api' },
      ]);
    });
  });

  describe('templates', () => {
    it('applies template settings to tasks', () => {
      const p = new Pipeline();
      const src = p.dir('.');

      const nodeTemplate = p.template('node')
        .container('node:20')
        .mount(src, '/app')
        .workdir('/app')
        .env('CI', 'true');

      p.task('test').from(nodeTemplate).run('npm test');
      p.task('lint').from(nodeTemplate).run('npm run lint');

      const json = p.toJSON();
      const tasks = json.tasks as any[];

      expect(tasks[0].container).toBe('node:20');
      expect(tasks[0].workdir).toBe('/app');
      expect(tasks[0].env).toEqual({ CI: 'true' });

      expect(tasks[1].container).toBe('node:20');
      expect(tasks[1].workdir).toBe('/app');
    });

    it('task settings override template settings', () => {
      const p = new Pipeline();

      const template = p.template('base').container('node:18').env('CI', 'true');

      p.task('test').from(template).container('node:20').run('npm test');

      const json = p.toJSON();
      // Task's container should NOT override since template is applied first
      // Actually, from() applies template, then container() is called after
      // So the task's container() call will override
      expect((json.tasks as any[])[0].container).toBe('node:20');
    });
  });

  describe('task groups', () => {
    it('creates parallel task groups', () => {
      const p = new Pipeline();
      const lint = p.task('lint').run('npm run lint');
      const test = p.task('test').run('npm test');
      const checks = p.parallel('checks', [lint, test]);

      p.task('build').run('npm run build').afterGroup(checks);

      const json = p.toJSON();
      const build = (json.tasks as any[]).find((t) => t.name === 'build');
      expect(build.depends_on).toContain('lint');
      expect(build.depends_on).toContain('test');
    });

    it('creates sequential chains', () => {
      const p = new Pipeline();
      const build = p.task('build').run('npm run build');
      const deploy = p.task('deploy').run('deploy.sh');
      const smoke = p.task('smoke').run('smoke.sh');

      p.chain(build, deploy, smoke);

      const json = p.toJSON();
      const deployTask = (json.tasks as any[]).find((t) => t.name === 'deploy');
      const smokeTask = (json.tasks as any[]).find((t) => t.name === 'smoke');

      expect(deployTask.depends_on).toContain('build');
      expect(smokeTask.depends_on).toContain('deploy');
    });
  });

  describe('presets', () => {
    it('tsInputs returns TypeScript file patterns', () => {
      const patterns = tsInputs();
      expect(patterns).toContain('**/*.ts');
      expect(patterns).toContain('**/*.tsx');
      expect(patterns).toContain('package.json');
    });
  });
});

// =============================================================================
// VALIDATION
// =============================================================================

describe('Validation', () => {
  describe('empty task names', () => {
    it('throws for empty string task name (early validation)', () => {
      const p = new Pipeline();
      // Now throws immediately on task() call due to early validation
      expect(() => p.task('').run('echo hi')).toThrow(ValidationError);
      expect(() => p.task('')).toThrow('cannot be empty');
    });

    it('throws for whitespace-only task name (early validation)', () => {
      const p = new Pipeline();
      expect(() => p.task('   ')).toThrow(ValidationError);
    });
  });

  describe('duplicate task names', () => {
    it('throws for duplicate task names (early validation)', () => {
      const p = new Pipeline();
      p.task('test').run('npm test');
      // Now throws immediately on second task() call
      expect(() => p.task('test')).toThrow(ValidationError);
      expect(() => p.task('test')).toThrow('Duplicate task name');
    });
  });

  describe('missing commands', () => {
    it('throws for task without run()', () => {
      const p = new Pipeline();
      p.task('test'); // No .run()

      expect(() => p.toJSON()).toThrow(ValidationError);
      expect(() => p.toJSON()).toThrow('has no command');
      expect(() => p.toJSON()).toThrow('did you forget to call .run()');
    });
  });

  describe('unknown dependencies', () => {
    it('throws for unknown dependency', () => {
      const p = new Pipeline();
      p.task('build').run('npm run build').after('test');
      // 'test' task doesn't exist

      expect(() => p.toJSON()).toThrow(ValidationError);
      expect(() => p.toJSON()).toThrow('unknown task "test"');
    });

    it('suggests similar task names', () => {
      const p = new Pipeline();
      p.task('test').run('npm test');
      p.task('build').run('npm run build').after('tset'); // typo

      expect(() => p.toJSON()).toThrow('did you mean "test"');
    });

    it('does not suggest dissimilar names', () => {
      const p = new Pipeline();
      p.task('lint').run('npm run lint');
      p.task('build').run('npm run build').after('xyz');

      try {
        p.toJSON();
        expect.fail('Should have thrown');
      } catch (e) {
        expect(e).toBeInstanceOf(ValidationError);
        expect((e as ValidationError).suggestion).toBeUndefined();
      }
    });
  });
});

// =============================================================================
// CYCLE DETECTION
// =============================================================================

describe('Cycle Detection', () => {
  it('detects direct self-cycle', () => {
    const p = new Pipeline();
    p.task('a').run('echo a').after('a');

    expect(() => p.toJSON()).toThrow(ValidationError);
    expect(() => p.toJSON()).toThrow('cycle');
  });

  it('detects simple A → B → A cycle', () => {
    const p = new Pipeline();
    p.task('a').run('echo a').after('b');
    p.task('b').run('echo b').after('a');

    expect(() => p.toJSON()).toThrow(ValidationError);
    expect(() => p.toJSON()).toThrow('cycle');
  });

  it('detects longer A → B → C → A cycle', () => {
    const p = new Pipeline();
    p.task('a').run('echo a').after('c');
    p.task('b').run('echo b').after('a');
    p.task('c').run('echo c').after('b');

    expect(() => p.toJSON()).toThrow(ValidationError);
    expect(() => p.toJSON()).toThrow('cycle');
  });

  it('allows valid DAG with diamond shape', () => {
    const p = new Pipeline();
    //     a
    //    / \
    //   b   c
    //    \ /
    //     d
    p.task('a').run('echo a');
    p.task('b').run('echo b').after('a');
    p.task('c').run('echo c').after('a');
    p.task('d').run('echo d').after('b', 'c');

    // Should not throw
    const json = p.toJSON();
    expect(json.tasks).toHaveLength(4);
  });

  it('allows valid linear chain', () => {
    const p = new Pipeline();
    p.task('a').run('echo a');
    p.task('b').run('echo b').after('a');
    p.task('c').run('echo c').after('b');
    p.task('d').run('echo d').after('c');

    const json = p.toJSON();
    expect(json.tasks).toHaveLength(4);
  });

  it('includes cycle path in error message', () => {
    const p = new Pipeline();
    p.task('build').run('build').after('deploy');
    p.task('deploy').run('deploy').after('build');

    try {
      p.toJSON();
      expect.fail('Should have thrown');
    } catch (e) {
      expect(e).toBeInstanceOf(ValidationError);
      expect((e as ValidationError).code).toBe('CYCLE_DETECTED');
      expect((e as Error).message).toMatch(/build.*→.*deploy|deploy.*→.*build/);
    }
  });
});

// =============================================================================
// K8S OPTIONS (MINIMAL API)
// =============================================================================

describe('K8s Options (Minimal API)', () => {
  it('sets memory and cpu', () => {
    const p = new Pipeline();
    p.task('build')
      .run('npm run build')
      .k8s({ memory: '4Gi', cpu: '2' });

    const json = p.toJSON();
    const task = (json.tasks as any[])[0];
    expect(task.k8s).toBeDefined();
    expect(task.k8s.memory).toBe('4Gi');
    expect(task.k8s.cpu).toBe('2');
  });

  it('sets gpu', () => {
    const p = new Pipeline();
    p.task('train')
      .run('python train.py')
      .k8s({ memory: '32Gi', gpu: 2 });

    const json = p.toJSON();
    const task = (json.tasks as any[])[0];
    expect(task.k8s.memory).toBe('32Gi');
    expect(task.k8s.gpu).toBe(2);
  });

  it('k8sRaw passes through advanced options', () => {
    const p = new Pipeline();
    p.task('gpu-train')
      .run('python train.py')
      .k8s({ memory: '32Gi', gpu: 1 })
      .k8sRaw('{"nodeSelector": {"gpu": "true"}, "tolerations": [{"key": "gpu", "effect": "NoSchedule"}]}');

    const json = p.toJSON();
    const task = (json.tasks as any[])[0];
    expect(task.k8s.memory).toBe('32Gi');
    expect(task.k8s.gpu).toBe(1);
    expect(task.k8s.raw).toContain('nodeSelector');
  });

  it('k8sRaw works without structured options', () => {
    const p = new Pipeline();
    p.task('custom')
      .run('echo test')
      .k8sRaw('{"serviceAccount": "my-sa"}');

    const json = p.toJSON();
    const task = (json.tasks as any[])[0];
    expect(task.k8s.raw).toContain('serviceAccount');
  });

  it('omits k8s field when no options set', () => {
    const p = new Pipeline();
    p.task('test').run('npm test');

    const json = p.toJSON();
    const task = (json.tasks as any[])[0];
    expect(task.k8s).toBeUndefined();
  });
});

// =============================================================================
// VALIDATION ERROR CLASS
// =============================================================================

describe('ValidationError', () => {
  it('includes code property', () => {
    const err = new ValidationError('test', 'EMPTY_NAME');
    expect(err.code).toBe('EMPTY_NAME');
    expect(err.name).toBe('ValidationError');
  });

  it('includes suggestion in message when provided', () => {
    const err = new ValidationError('Unknown task', 'UNKNOWN_DEPENDENCY', 'did you mean "test"?');
    expect(err.message).toContain('did you mean "test"');
    expect(err.suggestion).toBe('did you mean "test"?');
  });

  it('is an instance of Error', () => {
    const err = new ValidationError('test', 'CYCLE_DETECTED');
    expect(err).toBeInstanceOf(Error);
    expect(err).toBeInstanceOf(ValidationError);
  });
});

// =============================================================================
// EARLY VALIDATION (Fail-Fast)
// =============================================================================

describe('Early Validation', () => {
  describe('task()', () => {
    it('throws immediately for empty task name', () => {
      const p = new Pipeline();
      expect(() => p.task('')).toThrow(ValidationError);
    });

    it('throws immediately for duplicate task name', () => {
      const p = new Pipeline();
      p.task('test').run('npm test');
      expect(() => p.task('test')).toThrow('Duplicate task name');
    });
  });

  describe('template()', () => {
    it('throws immediately for empty template name', () => {
      const p = new Pipeline();
      expect(() => p.template('')).toThrow(ValidationError);
    });

    it('throws immediately for duplicate template name', () => {
      const p = new Pipeline();
      p.template('node').container('node:20');
      expect(() => p.template('node')).toThrow('Duplicate template name');
    });
  });

  describe('dir()', () => {
    it('throws immediately for empty directory path', () => {
      const p = new Pipeline();
      expect(() => p.dir('')).toThrow(ValidationError);
    });
  });

  describe('cache()', () => {
    it('throws immediately for empty cache name', () => {
      const p = new Pipeline();
      expect(() => p.cache('')).toThrow(ValidationError);
    });
  });
});

// =============================================================================
// EXPLAIN (Dry-run Visualization)
// =============================================================================

describe('Explain', () => {
  it('generates basic execution plan', () => {
    const p = new Pipeline();
    p.task('test').run('npm test');
    p.task('build').run('npm run build').after('test');

    const plan = p.explain();
    expect(plan).toContain('Pipeline Execution Plan');
    expect(plan).toContain('1. test');
    expect(plan).toContain('Command: npm test');
    expect(plan).toContain('2. build (after: test)');
    expect(plan).toContain('Command: npm run build');
  });

  it('shows tasks in topological order', () => {
    const p = new Pipeline();
    p.task('deploy').run('deploy.sh').after('build');
    p.task('build').run('npm run build').after('test');
    p.task('test').run('npm test');

    const plan = p.explain();
    const testIdx = plan.indexOf('test');
    const buildIdx = plan.indexOf('build');
    const deployIdx = plan.indexOf('deploy');

    // test should come before build, build before deploy
    expect(testIdx).toBeLessThan(buildIdx);
    expect(buildIdx).toBeLessThan(deployIdx);
  });

  it('shows container info', () => {
    const p = new Pipeline();
    p.task('test').container('node:20').run('npm test');

    const plan = p.explain();
    expect(plan).toContain('Container: node:20');
  });

  it('shows condition info', () => {
    const p = new Pipeline();
    p.task('deploy').run('deploy.sh').whenCond(branch('main'));

    const plan = p.explain();
    expect(plan).toContain("Condition: branch == 'main'");
  });

  it('indicates skipped tasks based on branch context', () => {
    const p = new Pipeline();
    p.task('deploy').run('deploy.sh').whenCond(branch('main'));

    const plan = p.explain({ branch: 'feature/foo' });
    expect(plan).toContain('[SKIPPED:');
    expect(plan).toContain("branch is 'feature/foo'");
  });

  it('indicates skipped tasks based on tag context', () => {
    const p = new Pipeline();
    p.task('release').run('release.sh').whenCond(hasTag());

    const plan = p.explain({ tag: '' });
    expect(plan).toContain('[SKIPPED: no tag present]');
  });

  it('does not show skip for matching conditions', () => {
    const p = new Pipeline();
    p.task('deploy').run('deploy.sh').whenCond(branch('main'));

    const plan = p.explain({ branch: 'main' });
    expect(plan).not.toContain('[SKIPPED:');
  });
});

// =============================================================================
// JSON OUTPUT EDGE CASES
// =============================================================================

describe('JSON Output Edge Cases', () => {
  describe('services', () => {
    it('serializes service containers correctly', () => {
      const p = new Pipeline();
      p.task('test')
        .container('node:20')
        .service('postgres:15', 'db')
        .service('redis:7', 'cache')
        .run('npm test');

      const json = p.toJSON();
      const task = (json.tasks as any[])[0];
      expect(task.services).toEqual([
        { image: 'postgres:15', name: 'db' },
        { image: 'redis:7', name: 'cache' },
      ]);
    });
  });

  describe('matrix', () => {
    it('serializes matrix build correctly', () => {
      const p = new Pipeline();
      p.task('test')
        .run('npm test')
        .matrix('node', '18', '20', '22');

      const json = p.toJSON();
      const task = (json.tasks as any[])[0];
      expect(task.matrix).toEqual({ node: ['18', '20', '22'] });
    });
  });

  describe('retry and timeout', () => {
    it('serializes retry and timeout', () => {
      const p = new Pipeline();
      p.task('flaky').run('flaky-test.sh').retry(3).timeout(60);

      const json = p.toJSON();
      const task = (json.tasks as any[])[0];
      expect(task.retry).toBe(3);
      expect(task.timeout).toBe(60);
    });
  });

  describe('target', () => {
    it('serializes target for hybrid execution', () => {
      const p = new Pipeline();
      p.task('gpu-train').run('train.py').target('gpu-cluster');

      const json = p.toJSON();
      const task = (json.tasks as any[])[0];
      expect(task.target).toBe('gpu-cluster');
    });
  });

  describe('requires (node placement)', () => {
    it('serializes single required label', () => {
      const p = new Pipeline();
      p.task('train').run('python train.py').requires('gpu');

      const json = p.toJSON();
      const task = (json.tasks as any[])[0];
      expect(task.requires).toEqual(['gpu']);
    });

    it('serializes multiple required labels', () => {
      const p = new Pipeline();
      p.task('build').run('docker build').requires('docker', 'arm64');

      const json = p.toJSON();
      const task = (json.tasks as any[])[0];
      expect(task.requires).toEqual(['docker', 'arm64']);
    });

    it('accumulates labels from multiple calls', () => {
      const p = new Pipeline();
      p.task('heavy').run('heavy-task').requires('gpu').requires('high-memory');

      const json = p.toJSON();
      const task = (json.tasks as any[])[0];
      expect(task.requires).toEqual(['gpu', 'high-memory']);
    });

    it('omits requires when empty', () => {
      const p = new Pipeline();
      p.task('test').run('npm test');

      const json = p.toJSON();
      const task = (json.tasks as any[])[0];
      expect(task.requires).toBeUndefined();
    });
  });

  describe('task inputs (artifacts)', () => {
    it('serializes inputFrom correctly', () => {
      const p = new Pipeline();
      p.task('build').run('npm run build').output('dist', './dist');
      p.task('deploy').run('deploy.sh').inputFrom('build', 'dist', '/deploy/dist');

      const json = p.toJSON();
      const deploy = (json.tasks as any[]).find((t) => t.name === 'deploy');
      expect(deploy.task_inputs).toEqual([
        { from_task: 'build', output: 'dist', dest: '/deploy/dist' },
      ]);
      // Should also auto-add dependency
      expect(deploy.depends_on).toContain('build');
    });

    it('serializes outputs correctly', () => {
      const p = new Pipeline();
      p.task('build').run('npm run build').output('dist', './dist').output('docs', './docs');

      const json = p.toJSON();
      const task = (json.tasks as any[])[0];
      expect(task.outputs).toEqual({ dist: './dist', docs: './docs' });
    });
  });

  describe('outputs (v1 style auto-named)', () => {
    it('auto-generates output names', () => {
      const p = new Pipeline();
      p.task('build').run('npm run build').outputs('./dist', './docs');

      const json = p.toJSON();
      const task = (json.tasks as any[])[0];
      expect(task.outputs).toEqual({ output_0: './dist', output_1: './docs' });
    });

    it('single output gets output_0', () => {
      const p = new Pipeline();
      p.task('build').run('npm run build').outputs('./dist');

      const json = p.toJSON();
      const task = (json.tasks as any[])[0];
      expect(task.outputs).toEqual({ output_0: './dist' });
    });

    it('can mix output and outputs', () => {
      const p = new Pipeline();
      p.task('build').run('npm run build').output('binary', './app').outputs('./logs');

      const json = p.toJSON();
      const task = (json.tasks as any[])[0];
      expect(task.outputs.binary).toBe('./app');
      expect(task.outputs.output_0).toBe('./logs');
    });

    it('accumulates from multiple outputs() calls', () => {
      const p = new Pipeline();
      p.task('build').run('npm run build').outputs('./dist').outputs('./docs', './logs');

      const json = p.toJSON();
      const task = (json.tasks as any[])[0];
      expect(task.outputs).toEqual({
        output_0: './dist',
        output_1: './docs',
        output_2: './logs',
      });
    });
  });

  describe('K8s with raw JSON escape hatch', () => {
    it('serializes k8s options with raw JSON correctly', () => {
      const p = new Pipeline();
      p.task('gpu')
        .run('train.py')
        .k8s({ memory: '32Gi', cpu: '4', gpu: 2 })
        .k8sRaw('{"serviceAccount": "ml-runner", "nodeSelector": {"gpu-type": "nvidia"}}');

      const json = p.toJSON();
      const task = (json.tasks as any[])[0];
      expect(task.k8s.memory).toBe('32Gi');
      expect(task.k8s.cpu).toBe('4');
      expect(task.k8s.gpu).toBe(2);
      expect(task.k8s.raw).toContain('serviceAccount');
      expect(task.k8s.raw).toContain('nodeSelector');
    });
  });
});
