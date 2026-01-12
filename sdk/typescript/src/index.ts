/**
 * Sykli TypeScript SDK
 *
 * CI pipelines defined in TypeScript instead of YAML.
 *
 * @example
 * ```typescript
 * import { Pipeline } from 'sykli';
 *
 * const p = new Pipeline();
 * p.task('test').run('npm test');
 * p.task('build').run('npm run build').after('test');
 * p.emit();
 * ```
 */

// =============================================================================
// ERRORS
// =============================================================================

/** Validation error with helpful suggestions */
export class ValidationError extends Error {
  constructor(
    message: string,
    public readonly code: 'EMPTY_NAME' | 'DUPLICATE_TASK' | 'UNKNOWN_DEPENDENCY' | 'CYCLE_DETECTED' | 'MISSING_COMMAND',
    public readonly suggestion?: string
  ) {
    super(suggestion ? `${message} (${suggestion})` : message);
    this.name = 'ValidationError';
  }
}

// =============================================================================
// TYPES
// =============================================================================

/** Mount configuration for container tasks */
interface Mount {
  resource: string;
  path: string;
  type: 'directory' | 'cache';
}

/** Service container configuration */
interface Service {
  image: string;
  name: string;
}

/** Task input from another task's output */
interface TaskInput {
  fromTask: string;
  outputName: string;
  destPath: string;
}

/** Secret reference with explicit source */
export interface SecretRef {
  name: string;
  source: 'env' | 'file' | 'vault';
  key: string;
}

/** Create a secret reference from environment variable */
export function fromEnv(envVar: string): SecretRef {
  return { name: '', source: 'env', key: envVar };
}

/** Create a secret reference from file */
export function fromFile(path: string): SecretRef {
  return { name: '', source: 'file', key: path };
}

/** Create a secret reference from HashiCorp Vault */
export function fromVault(path: string): SecretRef {
  return { name: '', source: 'vault', key: path };
}

// =============================================================================
// CONDITIONS
// =============================================================================

/** Type-safe condition for when a task should run */
export class Condition {
  constructor(public readonly expr: string) {}

  /** Combine conditions with OR logic */
  or(other: Condition): Condition {
    return new Condition(`(${this.expr}) || (${other.expr})`);
  }

  /** Combine conditions with AND logic */
  and(other: Condition): Condition {
    return new Condition(`(${this.expr}) && (${other.expr})`);
  }

  toString(): string {
    return this.expr;
  }
}

/** Match a branch name or pattern */
export function branch(pattern: string): Condition {
  if (pattern.includes('*')) {
    return new Condition(`branch matches '${pattern}'`);
  }
  return new Condition(`branch == '${pattern}'`);
}

/** Match a tag name or pattern */
export function tag(pattern: string): Condition {
  if (!pattern) {
    return new Condition("tag != ''");
  }
  if (pattern.includes('*')) {
    return new Condition(`tag matches '${pattern}'`);
  }
  return new Condition(`tag == '${pattern}'`);
}

/** Match when any tag is present */
export function hasTag(): Condition {
  return new Condition("tag != ''");
}

/** Match a CI event type */
export function event(eventType: string): Condition {
  return new Condition(`event == '${eventType}'`);
}

/** Match when running in CI */
export function inCI(): Condition {
  return new Condition('ci == true');
}

/** Negate a condition */
export function not(c: Condition): Condition {
  return new Condition(`!(${c.expr})`);
}

// =============================================================================
// K8S OPTIONS (Minimal API)
// =============================================================================

/**
 * Kubernetes-specific configuration for a task.
 *
 * This is a minimal API covering 95% of CI use cases.
 * For advanced options (tolerations, affinity, security contexts),
 * use k8sRaw() to pass raw JSON.
 *
 * @example
 * ```typescript
 * p.task('build')
 *   .run('go build')
 *   .k8s({ memory: '4Gi', cpu: '2' });
 *
 * p.task('train')
 *   .run('python train.py')
 *   .k8s({ memory: '32Gi', gpu: 1 });
 * ```
 */
export interface K8sOptions {
  /** Memory (e.g., "4Gi", "512Mi"). Sets both request and limit. */
  memory?: string;
  /** CPU (e.g., "2", "500m"). Sets both request and limit. */
  cpu?: string;
  /** Number of NVIDIA GPUs to request. */
  gpu?: number;
}

// =============================================================================
// RESOURCES
// =============================================================================

/** Directory resource for mounting into containers */
export class Directory {
  private globs: string[] = [];

  constructor(
    private readonly pipeline: Pipeline,
    public readonly path: string
  ) {}

  /** Add glob patterns to filter the directory */
  glob(...patterns: string[]): this {
    this.globs.push(...patterns);
    return this;
  }

  /** Get the resource ID */
  id(): string {
    return `src:${this.path}`;
  }
}

/** Named cache volume that persists between runs */
export class CacheVolume {
  constructor(
    private readonly pipeline: Pipeline,
    public readonly name: string
  ) {}

  /** Get the resource ID */
  id(): string {
    return this.name;
  }
}

// =============================================================================
// TEMPLATE
// =============================================================================

/** Reusable task configuration template */
export class Template {
  private _container?: string;
  private _workdir?: string;
  private _env: Record<string, string> = {};
  private _mounts: Mount[] = [];

  constructor(
    private readonly pipeline: Pipeline,
    public readonly name: string
  ) {}

  /** Set the container image */
  container(image: string): this {
    this._container = image;
    return this;
  }

  /** Set the working directory */
  workdir(path: string): this {
    this._workdir = path;
    return this;
  }

  /** Set an environment variable */
  env(key: string, value: string): this {
    this._env[key] = value;
    return this;
  }

  /** Mount a directory */
  mount(dir: Directory, path: string): this {
    this._mounts.push({
      resource: dir.id(),
      path,
      type: 'directory',
    });
    return this;
  }

  /** Mount a cache volume */
  mountCache(cache: CacheVolume, path: string): this {
    this._mounts.push({
      resource: cache.id(),
      path,
      type: 'cache',
    });
    return this;
  }

  /** Apply template settings to a task (internal) */
  _applyTo(task: Task): void {
    if (this._container && !task._getContainer()) {
      task._setContainer(this._container);
    }
    if (this._workdir && !task._getWorkdir()) {
      task._setWorkdir(this._workdir);
    }
    const taskEnv = task._getEnv();
    for (const [k, v] of Object.entries(this._env)) {
      if (!(k in taskEnv)) {
        taskEnv[k] = v;
      }
    }
    task._setMounts([...this._mounts, ...task._getMounts()]);
  }
}

// =============================================================================
// TASK
// =============================================================================

/** A single task in the pipeline */
export class Task {
  private _command?: string;
  private _container?: string;
  private _workdir?: string;
  private _env: Record<string, string> = {};
  private _mounts: Mount[] = [];
  private _inputs: string[] = [];
  private _taskInputs: TaskInput[] = [];
  private _outputs: Record<string, string> = {};
  private _dependsOn: string[] = [];
  private _when?: string;
  private _whenCond?: Condition;
  private _secrets: string[] = [];
  private _secretRefs: SecretRef[] = [];
  private _matrix: Record<string, string[]> = {};
  private _services: Service[] = [];
  private _retry?: number;
  private _timeout?: number;
  private _target?: string;
  private _k8s?: K8sOptions;
  private _k8sRaw?: string;
  private _requires: string[] = [];

  constructor(
    private readonly pipeline: Pipeline,
    public readonly name: string
  ) {}

  /** Set the command to run */
  run(command: string): this {
    this._command = command;
    return this;
  }

  /** Apply a template's configuration */
  from(template: Template): this {
    template._applyTo(this);
    return this;
  }

  /** Set the container image */
  container(image: string): this {
    this._container = image;
    return this;
  }

  /** Mount a directory into the container */
  mount(dir: Directory, path: string): this {
    this._mounts.push({
      resource: dir.id(),
      path,
      type: 'directory',
    });
    return this;
  }

  /** Mount a cache volume */
  mountCache(cache: CacheVolume, path: string): this {
    this._mounts.push({
      resource: cache.id(),
      path,
      type: 'cache',
    });
    return this;
  }

  /** Mount current directory to /work and set workdir */
  mountCwd(): this {
    this._mounts.push({
      resource: 'src:.',
      path: '/work',
      type: 'directory',
    });
    this._workdir = '/work';
    return this;
  }

  /** Mount current directory to custom path and set workdir */
  mountCwdAt(containerPath: string): this {
    this._mounts.push({
      resource: 'src:.',
      path: containerPath,
      type: 'directory',
    });
    this._workdir = containerPath;
    return this;
  }

  /** Set the working directory */
  workdir(path: string): this {
    this._workdir = path;
    return this;
  }

  /** Set an environment variable */
  env(key: string, value: string): this {
    this._env[key] = value;
    return this;
  }

  /** Set input file patterns for caching */
  inputs(...patterns: string[]): this {
    this._inputs.push(...patterns);
    return this;
  }

  /** Declare a named output */
  output(name: string, path: string): this {
    this._outputs[name] = path;
    return this;
  }

  /** Declare outputs with auto-generated names (v1 style for backward compat) */
  outputs(...paths: string[]): this {
    // Determine how many auto-generated outputs already exist to avoid overwriting
    const existingAutoOutputsCount = Object.keys(this._outputs).filter((key) =>
      /^output_\d+$/.test(key)
    ).length;

    for (let i = 0; i < paths.length; i++) {
      this._outputs[`output_${existingAutoOutputsCount + i}`] = paths[i];
    }
    return this;
  }

  /** Consume an artifact from another task's output */
  inputFrom(fromTask: string, outputName: string, destPath: string): this {
    this._taskInputs.push({ fromTask, outputName, destPath });
    if (!this._dependsOn.includes(fromTask)) {
      this._dependsOn.push(fromTask);
    }
    return this;
  }

  /** Set dependencies - runs after these tasks */
  after(...tasks: string[]): this {
    this._dependsOn.push(...tasks);
    return this;
  }

  /** Set dependencies on a task group */
  afterGroup(group: TaskGroup): this {
    this._dependsOn.push(...group.taskNames());
    return this;
  }

  /** Set a string condition for when this task runs */
  when(condition: string): this {
    this._when = condition;
    return this;
  }

  /** Set a type-safe condition */
  whenCond(condition: Condition): this {
    this._whenCond = condition;
    return this;
  }

  /** Declare a required secret */
  secret(name: string): this {
    this._secrets.push(name);
    return this;
  }

  /** Declare multiple required secrets */
  secrets(...names: string[]): this {
    this._secrets.push(...names);
    return this;
  }

  /** Declare a typed secret reference */
  secretFrom(name: string, ref: SecretRef): this {
    this._secretRefs.push({ ...ref, name });
    return this;
  }

  /** Add a matrix dimension */
  matrix(key: string, ...values: string[]): this {
    this._matrix[key] = values;
    return this;
  }

  /** Add a service container */
  service(image: string, name: string): this {
    this._services.push({ image, name });
    return this;
  }

  /** Set retry count */
  retry(count: number): this {
    this._retry = count;
    return this;
  }

  /** Set timeout in seconds */
  timeout(seconds: number): this {
    this._timeout = seconds;
    return this;
  }

  /** Set the target for this task */
  target(name: string): this {
    this._target = name;
    return this;
  }

  /** Set Kubernetes-specific options */
  k8s(options: K8sOptions): this {
    this._k8s = options;
    return this;
  }

  /**
   * Add raw Kubernetes configuration as JSON.
   *
   * Use this for advanced options not covered by k8s() (tolerations, affinity, etc.).
   * The JSON is passed directly to the executor and merged with k8s options.
   * k8s() fields take precedence over k8sRaw for overlapping settings.
   *
   * @example
   * ```typescript
   * // GPU node with toleration
   * p.task('train')
   *   .k8s({ memory: '32Gi', gpu: 1 })
   *   .k8sRaw('{"nodeSelector": {"gpu": "true"}, "tolerations": [{"key": "gpu", "effect": "NoSchedule"}]}');
   * ```
   */
  k8sRaw(jsonConfig: string): this {
    this._k8sRaw = jsonConfig;
    return this;
  }

  /** Require node labels for task placement (mesh mode) */
  requires(...labels: string[]): this {
    this._requires.push(...labels);
    return this;
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // Internal accessors (for Template and Pipeline use)
  // ─────────────────────────────────────────────────────────────────────────────

  /** @internal Get container image */
  _getContainer(): string | undefined {
    return this._container;
  }

  /** @internal Set container image */
  _setContainer(image: string): void {
    this._container = image;
  }

  /** @internal Get workdir */
  _getWorkdir(): string | undefined {
    return this._workdir;
  }

  /** @internal Set workdir */
  _setWorkdir(path: string): void {
    this._workdir = path;
  }

  /** @internal Get env vars */
  _getEnv(): Record<string, string> {
    return this._env;
  }

  /** @internal Get mounts */
  _getMounts(): Mount[] {
    return this._mounts;
  }

  /** @internal Set mounts */
  _setMounts(mounts: Mount[]): void {
    this._mounts = mounts;
  }

  /** @internal Get dependencies */
  _getDependsOn(): string[] {
    return this._dependsOn;
  }

  /** @internal Get command */
  _getCommand(): string | undefined {
    return this._command;
  }

  /** @internal Get K8s options */
  _getK8s(): K8sOptions | undefined {
    return this._k8s;
  }

  /** @internal Set K8s options */
  _setK8s(opts: K8sOptions): void {
    this._k8s = opts;
  }

  /** Convert to JSON representation (internal) */
  _toJSON(): Record<string, unknown> {
    const json: Record<string, unknown> = {
      name: this.name,
      command: this._command,
    };

    if (this._container) json.container = this._container;
    if (this._workdir) json.workdir = this._workdir;
    if (Object.keys(this._env).length > 0) json.env = this._env;
    if (this._mounts.length > 0) {
      json.mounts = this._mounts.map((m) => ({
        resource: m.resource,
        path: m.path,
        type: m.type,
      }));
    }
    if (this._inputs.length > 0) json.inputs = this._inputs;
    if (this._taskInputs.length > 0) {
      json.task_inputs = this._taskInputs.map((ti) => ({
        from_task: ti.fromTask,
        output: ti.outputName,
        dest: ti.destPath,
      }));
    }
    if (Object.keys(this._outputs).length > 0) json.outputs = this._outputs;
    if (this._dependsOn.length > 0) json.depends_on = this._dependsOn;
    if (this._whenCond) {
      json.when = this._whenCond.toString();
    } else if (this._when) {
      json.when = this._when;
    }
    if (this._secrets.length > 0) json.secrets = this._secrets;
    if (this._secretRefs.length > 0) {
      json.secret_refs = this._secretRefs.map((sr) => ({
        name: sr.name,
        source: sr.source,
        key: sr.key,
      }));
    }
    if (Object.keys(this._matrix).length > 0) json.matrix = this._matrix;
    if (this._services.length > 0) {
      json.services = this._services.map((s) => ({
        image: s.image,
        name: s.name,
      }));
    }
    if (this._retry !== undefined) json.retry = this._retry;
    if (this._timeout !== undefined) json.timeout = this._timeout;
    if (this._target) json.target = this._target;
    // Include k8s if we have either structured options or raw JSON
    const k8sJson = this._k8sToJSON(this._k8s, this._k8sRaw);
    if (k8sJson) json.k8s = k8sJson;
    if (this._requires.length > 0) json.requires = this._requires;

    return json;
  }

  private _k8sToJSON(opts?: K8sOptions, raw?: string): Record<string, unknown> | null {
    if (!opts && !raw) return null;

    const json: Record<string, unknown> = {};

    if (opts?.memory) json.memory = opts.memory;
    if (opts?.cpu) json.cpu = opts.cpu;
    if (opts?.gpu) json.gpu = opts.gpu;
    if (raw) json.raw = raw;

    // Return null if empty
    if (Object.keys(json).length === 0) return null;

    return json;
  }
}

// =============================================================================
// TASK GROUP
// =============================================================================

/** A group of tasks (from Parallel or Matrix) */
export class TaskGroup {
  constructor(
    public readonly name: string,
    public readonly tasks: Task[]
  ) {}

  /** Get names of all tasks in this group */
  taskNames(): string[] {
    return this.tasks.map((t) => t.name);
  }

  /** Make all tasks in this group depend on given tasks */
  after(...tasks: string[]): this {
    for (const task of this.tasks) {
      task.after(...tasks);
    }
    return this;
  }

  /** Make all tasks depend on another group */
  afterGroup(group: TaskGroup): this {
    for (const task of this.tasks) {
      task.afterGroup(group);
    }
    return this;
  }
}

// =============================================================================
// PIPELINE
// =============================================================================

/** Pipeline options */
export interface PipelineOptions {
  k8sDefaults?: K8sOptions;
}

// DFS colors for cycle detection
const enum Color {
  WHITE = 0, // Unvisited
  GRAY = 1,  // In current path (visiting)
  BLACK = 2, // Completely processed
}

/** CI pipeline with tasks and resources */
export class Pipeline {
  private tasks: Task[] = [];
  private templates: Map<string, Template> = new Map();
  private directories: Directory[] = [];
  private caches: CacheVolume[] = [];
  private k8sDefaults?: K8sOptions;

  constructor(options?: PipelineOptions) {
    this.k8sDefaults = options?.k8sDefaults;
  }

  /** Create a new task (validates name immediately) */
  task(name: string): Task {
    // Fail-fast: validate name immediately
    if (!name || name.trim() === '') {
      throw new ValidationError('Task name cannot be empty', 'EMPTY_NAME');
    }
    // Check for duplicates immediately
    if (this.tasks.some((t) => t.name === name)) {
      throw new ValidationError(`Duplicate task name: "${name}"`, 'DUPLICATE_TASK');
    }
    const task = new Task(this, name);
    this.tasks.push(task);
    return task;
  }

  /** Create a reusable template (validates name immediately) */
  template(name: string): Template {
    if (!name || name.trim() === '') {
      throw new ValidationError('Template name cannot be empty', 'EMPTY_NAME');
    }
    if (this.templates.has(name)) {
      throw new ValidationError(`Duplicate template name: "${name}"`, 'DUPLICATE_TASK');
    }
    const template = new Template(this, name);
    this.templates.set(name, template);
    return template;
  }

  /** Create a directory resource (validates path immediately) */
  dir(path: string): Directory {
    if (!path || path.trim() === '') {
      throw new ValidationError('Directory path cannot be empty', 'EMPTY_NAME');
    }
    const dir = new Directory(this, path);
    this.directories.push(dir);
    return dir;
  }

  /** Create a cache volume (validates name immediately) */
  cache(name: string): CacheVolume {
    if (!name || name.trim() === '') {
      throw new ValidationError('Cache name cannot be empty', 'EMPTY_NAME');
    }
    const cache = new CacheVolume(this, name);
    this.caches.push(cache);
    return cache;
  }

  /** Create a parallel task group */
  parallel(name: string, tasks: Task[]): TaskGroup {
    return new TaskGroup(name, tasks);
  }

  /** Create a sequential chain */
  chain(...items: (Task | TaskGroup)[]): void {
    for (let i = 1; i < items.length; i++) {
      const prev = items[i - 1];
      const current = items[i];

      if (current instanceof Task) {
        if (prev instanceof Task) {
          current.after(prev.name);
        } else {
          current.afterGroup(prev);
        }
      } else {
        if (prev instanceof Task) {
          current.after(prev.name);
        } else {
          current.afterGroup(prev);
        }
      }
    }
  }

  /** Create tasks from a matrix of values */
  matrix<T>(
    name: string,
    values: T[],
    generator: (value: T) => Task
  ): TaskGroup {
    const tasks = values.map((v) => generator(v));
    return new TaskGroup(name, tasks);
  }

  /** Create tasks from a map of values */
  matrixMap<K extends string, V>(
    name: string,
    values: Record<K, V>,
    generator: (key: K, value: V) => Task
  ): TaskGroup {
    const tasks = Object.entries(values).map(([k, v]) =>
      generator(k as K, v as V)
    );
    return new TaskGroup(name, tasks);
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // Validation
  // ─────────────────────────────────────────────────────────────────────────────

  /**
   * Validate the pipeline and throw if errors are found.
   * Called automatically by toJSON() and emit().
   */
  validate(): void {
    const taskNames = new Set<string>();

    // Pass 1: Check for empty/duplicate names and missing commands
    for (const task of this.tasks) {
      // Empty name check
      if (!task.name || task.name.trim() === '') {
        throw new ValidationError(
          'Task name cannot be empty',
          'EMPTY_NAME'
        );
      }

      // Duplicate name check
      if (taskNames.has(task.name)) {
        throw new ValidationError(
          `Duplicate task name: "${task.name}"`,
          'DUPLICATE_TASK'
        );
      }
      taskNames.add(task.name);

      // Missing command check
      if (!task._getCommand()) {
        throw new ValidationError(
          `Task "${task.name}" has no command`,
          'MISSING_COMMAND',
          'did you forget to call .run()?'
        );
      }
    }

    // Pass 2: Check for unknown dependencies
    for (const task of this.tasks) {
      for (const dep of task._getDependsOn()) {
        if (!taskNames.has(dep)) {
          const suggestion = this.suggestTaskName(dep, taskNames);
          throw new ValidationError(
            `Task "${task.name}" depends on unknown task "${dep}"`,
            'UNKNOWN_DEPENDENCY',
            suggestion ? `did you mean "${suggestion}"?` : undefined
          );
        }
      }
    }

    // Pass 3: Cycle detection using 3-color DFS
    const cycle = this.detectCycle();
    if (cycle) {
      throw new ValidationError(
        `Dependency cycle detected: ${cycle.join(' → ')}`,
        'CYCLE_DETECTED'
      );
    }
  }

  /**
   * Detect cycles in the dependency graph using 3-color DFS.
   * Returns the cycle path if found, null otherwise.
   *
   * Algorithm:
   * - WHITE (0): Node not yet visited
   * - GRAY (1): Node is being processed (in current DFS path)
   * - BLACK (2): Node and all descendants fully processed
   *
   * A back edge to a GRAY node indicates a cycle.
   */
  private detectCycle(): string[] | null {
    // Build adjacency list: task name → dependencies
    const deps = new Map<string, string[]>();
    for (const task of this.tasks) {
      deps.set(task.name, task._getDependsOn());
    }

    const color = new Map<string, Color>();
    const parent = new Map<string, string>();

    // Initialize all nodes as WHITE
    for (const task of this.tasks) {
      color.set(task.name, Color.WHITE);
    }

    // DFS from each unvisited node
    for (const task of this.tasks) {
      if (color.get(task.name) === Color.WHITE) {
        const cycle = this.dfsDetectCycle(task.name, deps, color, parent);
        if (cycle) {
          return cycle;
        }
      }
    }

    return null;
  }

  /**
   * DFS helper for cycle detection.
   */
  private dfsDetectCycle(
    node: string,
    deps: Map<string, string[]>,
    color: Map<string, Color>,
    parent: Map<string, string>
  ): string[] | null {
    color.set(node, Color.GRAY);

    for (const dep of deps.get(node) || []) {
      if (color.get(dep) === Color.GRAY) {
        // Found a back edge - reconstruct cycle
        return this.reconstructCycle(node, dep, parent);
      }
      if (color.get(dep) === Color.WHITE) {
        parent.set(dep, node);
        const cycle = this.dfsDetectCycle(dep, deps, color, parent);
        if (cycle) {
          return cycle;
        }
      }
    }

    color.set(node, Color.BLACK);
    return null;
  }

  /**
   * Reconstruct the cycle path from the detected back edge.
   */
  private reconstructCycle(from: string, to: string, parent: Map<string, string>): string[] {
    const cycle: string[] = [to];
    let current = from;
    while (current !== to) {
      cycle.unshift(current);
      current = parent.get(current) || to;
    }
    cycle.unshift(to); // Close the cycle
    return cycle;
  }

  /**
   * Find the most similar task name using Jaro-Winkler similarity.
   * Returns suggestion if similarity >= 0.8, undefined otherwise.
   */
  private suggestTaskName(unknown: string, known: Set<string>): string | undefined {
    let best: string | undefined;
    let bestScore = 0;

    for (const name of known) {
      const score = jaroWinkler(unknown, name);
      if (score > bestScore && score >= 0.8) {
        bestScore = score;
        best = name;
      }
    }

    return best;
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // K8s Options Merging
  // ─────────────────────────────────────────────────────────────────────────────

  /**
   * Merge pipeline K8s defaults with task-specific K8s options.
   * Task options take precedence over defaults.
   */
  private mergeK8sOptions(taskOpts?: K8sOptions): K8sOptions | undefined {
    if (!this.k8sDefaults && !taskOpts) {
      return undefined;
    }
    if (!this.k8sDefaults) {
      return taskOpts;
    }
    if (!taskOpts) {
      return this.k8sDefaults;
    }

    // Deep merge with task options taking precedence
    return {
      namespace: taskOpts.namespace ?? this.k8sDefaults.namespace,
      nodeSelector: { ...this.k8sDefaults.nodeSelector, ...taskOpts.nodeSelector },
      tolerations: taskOpts.tolerations ?? this.k8sDefaults.tolerations,
      priorityClassName: taskOpts.priorityClassName ?? this.k8sDefaults.priorityClassName,
      resources: taskOpts.resources ?? this.k8sDefaults.resources,
      gpu: taskOpts.gpu ?? this.k8sDefaults.gpu,
      serviceAccount: taskOpts.serviceAccount ?? this.k8sDefaults.serviceAccount,
      securityContext: taskOpts.securityContext ?? this.k8sDefaults.securityContext,
      hostNetwork: taskOpts.hostNetwork ?? this.k8sDefaults.hostNetwork,
      dnsPolicy: taskOpts.dnsPolicy ?? this.k8sDefaults.dnsPolicy,
      volumes: taskOpts.volumes ?? this.k8sDefaults.volumes,
      labels: { ...this.k8sDefaults.labels, ...taskOpts.labels },
      annotations: { ...this.k8sDefaults.annotations, ...taskOpts.annotations },
    };
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // Emit / JSON
  // ─────────────────────────────────────────────────────────────────────────────

  /** Emit pipeline as JSON if --emit flag is present */
  emit(): void {
    if (process.argv.includes('--emit')) {
      console.log(JSON.stringify(this.toJSON(), null, 2));
      process.exit(0);
    }
  }

  /** Convert pipeline to JSON (validates first) */
  toJSON(): Record<string, unknown> {
    // Validate before emitting
    this.validate();

    // Apply K8s defaults to all tasks
    for (const task of this.tasks) {
      const merged = this.mergeK8sOptions(task._getK8s());
      if (merged) {
        task._setK8s(merged);
      }
    }

    const hasV2Features =
      this.directories.length > 0 ||
      this.caches.length > 0 ||
      this.tasks.some((t) => t._getContainer() || t._getMounts().length > 0);

    const json: Record<string, unknown> = {
      version: hasV2Features ? '2' : '1',
      tasks: this.tasks.map((t) => t._toJSON()),
    };

    if (hasV2Features) {
      const resources: Record<string, unknown> = {};
      for (const dir of this.directories) {
        resources[dir.id()] = {
          type: 'directory',
          path: dir.path,
        };
      }
      for (const cache of this.caches) {
        resources[cache.id()] = {
          type: 'cache',
          name: cache.name,
        };
      }
      if (Object.keys(resources).length > 0) {
        json.resources = resources;
      }
    }

    return json;
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // Explain (Dry-run visualization)
  // ─────────────────────────────────────────────────────────────────────────────

  /** Context for evaluating conditions in explain() */
  static ExplainContext = class {
    constructor(
      public branch = '',
      public tag = '',
      public event = '',
      public ci = false
    ) {}
  };

  /**
   * Print a human-readable execution plan without running anything.
   * Useful for debugging pipelines and understanding what will run.
   *
   * @param ctx - Optional context for evaluating conditions
   * @returns The execution plan as a string
   *
   * @example
   * ```typescript
   * const p = new Pipeline();
   * p.task('test').run('npm test');
   * p.task('build').run('npm run build').after('test');
   * p.task('deploy').run('deploy.sh').whenCond(branch('main'));
   *
   * console.log(p.explain({ branch: 'feature/foo' }));
   * // Output:
   * // Pipeline Execution Plan
   * // =======================
   * // 1. test
   * //    Command: npm test
   * //
   * // 2. build (after: test)
   * //    Command: npm run build
   * //
   * // 3. deploy (after: build) [SKIPPED: branch is 'feature/foo', not 'main']
   * //    Command: deploy.sh
   * //    Condition: branch == 'main'
   * ```
   */
  explain(ctx?: { branch?: string; tag?: string; event?: string; ci?: boolean }): string {
    const context = {
      branch: ctx?.branch ?? '',
      tag: ctx?.tag ?? '',
      event: ctx?.event ?? '',
      ci: ctx?.ci ?? false,
    };

    // Topological sort for display order
    const sorted = this.topologicalSort();
    const lines: string[] = [];

    lines.push('Pipeline Execution Plan');
    lines.push('=======================');
    lines.push('');

    for (let i = 0; i < sorted.length; i++) {
      const task = sorted[i];
      const deps = task._getDependsOn();
      const condition = this.getTaskCondition(task);

      // Build header
      let header = `${i + 1}. ${task.name}`;
      if (deps.length > 0) {
        header += ` (after: ${deps.join(', ')})`;
      }

      // Check if skipped
      const skipReason = this.wouldSkip(task, context);
      if (skipReason) {
        header += ` [SKIPPED: ${skipReason}]`;
      }

      lines.push(header);
      lines.push(`   Command: ${task._getCommand()}`);

      if (condition) {
        lines.push(`   Condition: ${condition}`);
      }

      const container = task._getContainer();
      if (container) {
        lines.push(`   Container: ${container}`);
      }

      lines.push('');
    }

    return lines.join('\n');
  }

  /**
   * Topological sort using Kahn's algorithm.
   * Returns tasks in dependency order for display.
   */
  private topologicalSort(): Task[] {
    const inDegree = new Map<string, number>();
    const taskMap = new Map<string, Task>();

    // Initialize
    for (const task of this.tasks) {
      taskMap.set(task.name, task);
      inDegree.set(task.name, 0);
    }

    // Count in-degrees
    for (const task of this.tasks) {
      const deps = task._getDependsOn();
      // Task depends on N other tasks, so its in-degree is N
      inDegree.set(task.name, deps.length);
    }

    // Kahn's algorithm
    const queue: string[] = [];
    for (const [name, degree] of inDegree) {
      if (degree === 0) {
        queue.push(name);
      }
    }

    const sorted: Task[] = [];
    while (queue.length > 0) {
      const name = queue.shift()!;
      sorted.push(taskMap.get(name)!);

      // For each task that depends on this one
      for (const task of this.tasks) {
        if (task._getDependsOn().includes(name)) {
          inDegree.set(task.name, (inDegree.get(task.name) || 0) - 1);
          if (inDegree.get(task.name) === 0) {
            queue.push(task.name);
          }
        }
      }
    }

    return sorted;
  }

  /**
   * Get the effective condition string for a task.
   */
  private getTaskCondition(task: Task): string | undefined {
    // Access internal state via JSON output
    const json = task._toJSON();
    return json.when as string | undefined;
  }

  /**
   * Check if a task would be skipped given the context.
   * Returns skip reason or undefined if task would run.
   */
  private wouldSkip(
    task: Task,
    ctx: { branch: string; tag: string; event: string; ci: boolean }
  ): string | undefined {
    const condition = this.getTaskCondition(task);
    if (!condition) return undefined;

    // Simple condition evaluation (handles common cases)
    const cond = condition.trim();

    // branch == 'value'
    const branchEq = cond.match(/^branch == '([^']+)'$/);
    if (branchEq && ctx.branch !== branchEq[1]) {
      return `branch is '${ctx.branch}', not '${branchEq[1]}'`;
    }

    // branch != 'value'
    const branchNeq = cond.match(/^branch != '([^']+)'$/);
    if (branchNeq && ctx.branch === branchNeq[1]) {
      return `branch is '${ctx.branch}'`;
    }

    // tag != '' (has tag)
    if (cond === "tag != ''" && !ctx.tag) {
      return 'no tag present';
    }

    // ci == true
    if (cond === 'ci == true' && !ctx.ci) {
      return 'not running in CI';
    }

    // event == 'value'
    const eventEq = cond.match(/^event == '([^']+)'$/);
    if (eventEq && ctx.event !== eventEq[1]) {
      return `event is '${ctx.event}', not '${eventEq[1]}'`;
    }

    return undefined;
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // Language Presets
  // ─────────────────────────────────────────────────────────────────────────────

  /** Get Node.js preset builder for common Node tasks */
  node(): NodePreset {
    return new NodePreset(this);
  }

  /** Get TypeScript preset builder for common TypeScript tasks */
  typescript(): TypeScriptPreset {
    return new TypeScriptPreset(this);
  }
}

// =============================================================================
// LANGUAGE PRESETS
// =============================================================================

/**
 * Node.js preset - provides common tasks for Node projects.
 *
 * @example
 * ```typescript
 * const p = new Pipeline();
 * p.node().test();                    // Creates 'test' task with 'npm test'
 * p.node().lint();                    // Creates 'lint' task with 'npm run lint'
 * p.node().build().after('test');     // Creates 'build' task with dependency
 * p.emit();
 * ```
 */
export class NodePreset {
  constructor(private pipeline: Pipeline) {}

  /** Creates a 'test' task running 'npm test' with standard Node inputs */
  test(): Task {
    return this.pipeline.task('test').run('npm test').inputs(...nodeInputs());
  }

  /** Creates a 'lint' task running 'npm run lint' with standard Node inputs */
  lint(): Task {
    return this.pipeline.task('lint').run('npm run lint').inputs(...nodeInputs());
  }

  /** Creates a 'build' task running 'npm run build' with standard Node inputs */
  build(): Task {
    return this.pipeline.task('build').run('npm run build').inputs(...nodeInputs());
  }

  /** Creates an 'install' task running 'npm ci' */
  install(): Task {
    return this.pipeline.task('install').run('npm ci').inputs('package.json', 'package-lock.json');
  }
}

/**
 * TypeScript preset - provides common tasks for TypeScript projects.
 *
 * @example
 * ```typescript
 * const p = new Pipeline();
 * p.typescript().typecheck();         // Creates 'typecheck' task with 'npx tsc --noEmit'
 * p.typescript().test();              // Creates 'test' task
 * p.typescript().build();             // Creates 'build' task
 * p.emit();
 * ```
 */
export class TypeScriptPreset {
  constructor(private pipeline: Pipeline) {}

  /** Creates a 'test' task running 'npm test' with standard TypeScript inputs */
  test(): Task {
    return this.pipeline.task('test').run('npm test').inputs(...tsInputs());
  }

  /** Creates a 'lint' task running 'npm run lint' with standard TypeScript inputs */
  lint(): Task {
    return this.pipeline.task('lint').run('npm run lint').inputs(...tsInputs());
  }

  /** Creates a 'build' task running 'npm run build' with standard TypeScript inputs */
  build(): Task {
    return this.pipeline.task('build').run('npm run build').inputs(...tsInputs());
  }

  /** Creates a 'typecheck' task running 'npx tsc --noEmit' */
  typecheck(): Task {
    return this.pipeline.task('typecheck').run('npx tsc --noEmit').inputs(...tsInputs());
  }

  /** Creates an 'install' task running 'npm ci' */
  install(): Task {
    return this.pipeline.task('install').run('npm ci').inputs('package.json', 'package-lock.json');
  }
}

// =============================================================================
// STRING SIMILARITY (Jaro-Winkler)
// =============================================================================

/**
 * Compute Jaro-Winkler similarity between two strings (0-1).
 * Used for "did you mean?" suggestions.
 */
function jaroWinkler(s1: string, s2: string): number {
  if (s1 === s2) return 1.0;
  if (s1.length === 0 || s2.length === 0) return 0.0;

  // Compute Jaro similarity
  const matchWindow = Math.max(Math.floor(Math.max(s1.length, s2.length) / 2) - 1, 0);

  const s1Matches = new Array(s1.length).fill(false);
  const s2Matches = new Array(s2.length).fill(false);

  let matches = 0;
  let transpositions = 0;

  // Find matches
  for (let i = 0; i < s1.length; i++) {
    const start = Math.max(0, i - matchWindow);
    const end = Math.min(s2.length, i + matchWindow + 1);

    for (let j = start; j < end; j++) {
      if (s2Matches[j] || s1[i] !== s2[j]) continue;
      s1Matches[i] = true;
      s2Matches[j] = true;
      matches++;
      break;
    }
  }

  if (matches === 0) return 0.0;

  // Count transpositions
  let k = 0;
  for (let i = 0; i < s1.length; i++) {
    if (!s1Matches[i]) continue;
    while (!s2Matches[k]) k++;
    if (s1[i] !== s2[k]) transpositions++;
    k++;
  }

  const jaro =
    (matches / s1.length + matches / s2.length + (matches - transpositions / 2) / matches) / 3.0;

  // Apply Winkler prefix bonus
  let prefix = 0;
  for (let i = 0; i < Math.min(4, Math.min(s1.length, s2.length)); i++) {
    if (s1[i] === s2[i]) prefix++;
    else break;
  }

  return jaro + prefix * 0.1 * (1 - jaro);
}

// =============================================================================
// PRESETS
// =============================================================================

/** Standard TypeScript/JavaScript input patterns */
export function tsInputs(): string[] {
  return ['**/*.ts', '**/*.tsx', '**/*.js', '**/*.jsx', 'package.json', 'package-lock.json'];
}

/** Standard Node.js input patterns */
export function nodeInputs(): string[] {
  return ['**/*.js', '**/*.mjs', '**/*.cjs', 'package.json', 'package-lock.json'];
}
