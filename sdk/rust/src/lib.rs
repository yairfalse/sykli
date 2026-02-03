//! Sykli - CI pipelines defined in Rust instead of YAML
//!
//! # Simple usage
//!
//! ```rust,no_run
//! use sykli::Pipeline;
//!
//! let mut p = Pipeline::new();
//! p.task("test").run("cargo test");
//! p.task("build").run("cargo build --release").after(&["test"]);
//! p.emit();
//! ```
//!
//! # With containers and caching
//!
//! ```rust,no_run
//! use sykli::Pipeline;
//!
//! let mut p = Pipeline::new();
//! let src = p.dir(".");
//! let cache = p.cache("cargo-registry");
//!
//! p.task("test")
//!     .container("rust:1.75")
//!     .mount(&src, "/src")
//!     .mount_cache(&cache, "/usr/local/cargo/registry")
//!     .workdir("/src")
//!     .run("cargo test");
//!
//! p.emit();
//! ```
//!
//! # Custom Targets
//!
//! For implementing custom execution targets, see the [`target`] module.
//!
//! ```rust,ignore
//! use sykli::target::{Target, TaskSpec, Result};
//!
//! struct MyTarget;
//!
//! impl Target for MyTarget {
//!     fn run_task(&self, task: &TaskSpec) -> Result {
//!         // Execute tasks your way
//!         Result::success()
//!     }
//! }
//! ```

pub mod target;

use regex::Regex;
use serde::Serialize;
use std::collections::HashMap;
use std::env;
use std::io::{self, Write};
use std::sync::LazyLock;
use tracing::debug;

// K8s resource validation patterns
static K8S_MEMORY_PATTERN: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^[0-9]+(\.[0-9]+)?(Ki|Mi|Gi|Ti|Pi|Ei|k|M|G|T|P|E)?$").unwrap());
static K8S_CPU_PATTERN: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^[0-9]+(\.[0-9]+)?m?$").unwrap());

// =============================================================================
// RESOURCES
// =============================================================================

/// A directory resource that can be mounted into containers.
#[derive(Clone)]
pub struct Directory {
    path: String,
    globs: Vec<String>,
}

impl Directory {
    /// Returns the resource ID for this directory.
    pub fn id(&self) -> String {
        format!("src:{}", self.path)
    }

    /// Adds glob patterns to filter the directory.
    pub fn glob(mut self, patterns: &[&str]) -> Self {
        self.globs.extend(patterns.iter().map(|s| s.to_string()));
        self
    }
}

/// A named cache volume that persists between runs.
#[derive(Clone)]
pub struct CacheVolume {
    name: String,
}

impl CacheVolume {
    /// Returns the resource ID for this cache.
    pub fn id(&self) -> String {
        self.name.clone()
    }
}

// =============================================================================
// MOUNT
// =============================================================================

#[derive(Clone)]
struct Mount {
    resource: String,
    path: String,
    mount_type: String,
}

#[derive(Clone)]
struct Service {
    image: String,
    name: String,
}

// =============================================================================
// K8S OPTIONS (Minimal API)
// =============================================================================

/// Kubernetes-specific configuration for a task.
///
/// This is a minimal API covering 95% of CI use cases.
/// For advanced options (tolerations, affinity, security contexts),
/// use `k8s_raw()` to pass raw JSON.
///
/// # Example
/// ```rust,ignore
/// use sykli::{Pipeline, K8sOptions};
///
/// let mut p = Pipeline::new();
/// p.task("build")
///     .run("cargo build")
///     .k8s(K8sOptions {
///         memory: Some("4Gi".into()),
///         cpu: Some("2".into()),
///         ..Default::default()
///     });
///
/// // For GPU tasks
/// p.task("train")
///     .run("python train.py")
///     .k8s(K8sOptions {
///         memory: Some("32Gi".into()),
///         gpu: Some(1),
///         ..Default::default()
///     });
/// ```
#[derive(Clone, Default, Debug)]
pub struct K8sOptions {
    /// Memory (e.g., "4Gi", "512Mi"). Sets both request and limit.
    pub memory: Option<String>,
    /// CPU (e.g., "2", "500m"). Sets both request and limit.
    pub cpu: Option<String>,
    /// Number of NVIDIA GPUs to request.
    pub gpu: Option<u32>,
}

impl K8sOptions {
    /// Merges defaults with task-specific options.
    /// Task options override defaults.
    pub fn merge(defaults: &K8sOptions, task: &K8sOptions) -> K8sOptions {
        let mut result = defaults.clone();

        if task.memory.is_some() {
            result.memory = task.memory.clone();
        }
        if task.cpu.is_some() {
            result.cpu = task.cpu.clone();
        }
        if task.gpu.is_some() {
            result.gpu = task.gpu;
        }

        result
    }

    /// Returns true if no options are set.
    pub fn is_empty(&self) -> bool {
        self.memory.is_none() && self.cpu.is_none() && self.gpu.is_none()
    }

    /// Validates K8s options and returns a list of errors.
    pub fn validate(&self) -> Vec<K8sValidationError> {
        let mut errors = Vec::new();

        if let Some(ref v) = self.memory {
            if let Some(err) = validate_k8s_memory("memory", v) {
                errors.push(err);
            }
        }

        if let Some(ref v) = self.cpu {
            if let Some(err) = validate_k8s_cpu("cpu", v) {
                errors.push(err);
            }
        }

        errors
    }
}

/// Error from K8s options validation.
#[derive(Debug, Clone)]
pub struct K8sValidationError {
    /// Field that failed validation (e.g., "resources.memory").
    pub field: String,
    /// The invalid value.
    pub value: String,
    /// Description of what's wrong.
    pub message: String,
}

impl std::fmt::Display for K8sValidationError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "k8s.{}: {} (got {:?})",
            self.field, self.message, self.value
        )
    }
}

impl std::error::Error for K8sValidationError {}

fn validate_k8s_memory(field: &str, value: &str) -> Option<K8sValidationError> {
    if K8S_MEMORY_PATTERN.is_match(value) {
        return None;
    }

    // Provide helpful suggestions for common mistakes
    let lower = value.to_lowercase();
    let suggestion = if lower.ends_with("gb") {
        " (did you mean 'Gi'?)"
    } else if lower.ends_with("mb") {
        " (did you mean 'Mi'?)"
    } else if lower.ends_with("kb") {
        " (did you mean 'Ki'?)"
    } else {
        ""
    };

    Some(K8sValidationError {
        field: field.to_string(),
        value: value.to_string(),
        message: format!(
            "invalid memory format, use Ki/Mi/Gi/Ti (e.g., '512Mi', '4Gi'){}",
            suggestion
        ),
    })
}

fn validate_k8s_cpu(field: &str, value: &str) -> Option<K8sValidationError> {
    if K8S_CPU_PATTERN.is_match(value) {
        return None;
    }

    Some(K8sValidationError {
        field: field.to_string(),
        value: value.to_string(),
        message: "invalid CPU format, use cores or millicores (e.g., '500m', '0.5', '2')"
            .to_string(),
    })
}

// =============================================================================
// STRING SIMILARITY
// =============================================================================

/// Finds the most similar task name using Jaro-Winkler distance.
fn suggest_task_name<'a>(unknown: &str, known: &[&'a str]) -> Option<&'a str> {
    let mut best: Option<&str> = None;
    let mut best_score = 0.0;

    for &name in known {
        let score = jaro_winkler(unknown, name);
        if score > best_score && score >= 0.8 {
            best_score = score;
            best = Some(name);
        }
    }
    best
}

/// Computes the Jaro-Winkler similarity between two strings (0-1).
fn jaro_winkler(s1: &str, s2: &str) -> f64 {
    if s1 == s2 {
        return 1.0;
    }
    if s1.is_empty() || s2.is_empty() {
        return 0.0;
    }

    let s1_chars: Vec<char> = s1.chars().collect();
    let s2_chars: Vec<char> = s2.chars().collect();

    let match_window = (s1_chars.len().max(s2_chars.len()) / 2).saturating_sub(1);

    let mut s1_matches = vec![false; s1_chars.len()];
    let mut s2_matches = vec![false; s2_chars.len()];

    let mut matches = 0usize;
    let mut transpositions = 0usize;

    for i in 0..s1_chars.len() {
        let start = i.saturating_sub(match_window);
        let end = (i + match_window + 1).min(s2_chars.len());

        for j in start..end {
            if s2_matches[j] || s1_chars[i] != s2_chars[j] {
                continue;
            }
            s1_matches[i] = true;
            s2_matches[j] = true;
            matches += 1;
            break;
        }
    }

    if matches == 0 {
        return 0.0;
    }

    let mut k = 0;
    for i in 0..s1_chars.len() {
        if !s1_matches[i] {
            continue;
        }
        while !s2_matches[k] {
            k += 1;
        }
        if s1_chars[i] != s2_chars[k] {
            transpositions += 1;
        }
        k += 1;
    }

    let jaro = (matches as f64 / s1_chars.len() as f64
        + matches as f64 / s2_chars.len() as f64
        + (matches as f64 - transpositions as f64 / 2.0) / matches as f64)
        / 3.0;

    // Apply Winkler prefix bonus
    let mut prefix = 0;
    for i in 0..4.min(s1_chars.len()).min(s2_chars.len()) {
        if s1_chars[i] == s2_chars[i] {
            prefix += 1;
        } else {
            break;
        }
    }

    jaro + prefix as f64 * 0.1 * (1.0 - jaro)
}

// =============================================================================
// TEMPLATE
// =============================================================================

/// A reusable task configuration template.
///
/// Templates allow you to define common settings (container, mounts, env)
/// that can be inherited by multiple tasks via `from()`.
///
/// # Example
/// ```rust
/// use sykli::{Pipeline, Template};
///
/// let mut p = Pipeline::new();
/// let src = p.dir(".");
///
/// let rust = Template::new()
///     .container("rust:1.75")
///     .mount_dir(&src, "/src")
///     .workdir("/src");
///
/// p.task("test").from(&rust).run("cargo test");
/// p.task("build").from(&rust).run("cargo build");
/// ```
#[derive(Clone, Default)]
pub struct Template {
    container: Option<String>,
    workdir: Option<String>,
    env: HashMap<String, String>,
    mounts: Vec<Mount>,
}

impl Template {
    /// Creates a new empty template.
    #[must_use]
    pub fn new() -> Self {
        Template::default()
    }

    /// Sets the container image for tasks using this template.
    #[must_use]
    pub fn container(mut self, image: &str) -> Self {
        assert!(!image.is_empty(), "container image cannot be empty");
        self.container = Some(image.to_string());
        self
    }

    /// Sets the working directory for tasks using this template.
    #[must_use]
    pub fn workdir(mut self, path: &str) -> Self {
        assert!(!path.is_empty(), "workdir cannot be empty");
        assert!(path.starts_with('/'), "workdir must be absolute");
        self.workdir = Some(path.to_string());
        self
    }

    /// Sets an environment variable for tasks using this template.
    #[must_use]
    pub fn env(mut self, key: &str, value: &str) -> Self {
        assert!(!key.is_empty(), "env key cannot be empty");
        self.env.insert(key.to_string(), value.to_string());
        self
    }

    /// Adds a directory mount for tasks using this template.
    #[must_use]
    pub fn mount_dir(mut self, dir: &Directory, path: &str) -> Self {
        assert!(!path.is_empty(), "mount path cannot be empty");
        assert!(path.starts_with('/'), "mount path must be absolute");
        self.mounts.push(Mount {
            resource: dir.id(),
            path: path.to_string(),
            mount_type: "directory".to_string(),
        });
        self
    }

    /// Adds a cache mount for tasks using this template.
    #[must_use]
    pub fn mount_cache(mut self, cache: &CacheVolume, path: &str) -> Self {
        assert!(!path.is_empty(), "mount path cannot be empty");
        assert!(path.starts_with('/'), "mount path must be absolute");
        self.mounts.push(Mount {
            resource: cache.id(),
            path: path.to_string(),
            mount_type: "cache".to_string(),
        });
        self
    }
}

// =============================================================================
// TASK
// =============================================================================

/// A task in the pipeline.
pub struct Task<'a> {
    pipeline: &'a mut Pipeline,
    index: usize,
}

/// Represents an input artifact from another task's output.
#[derive(Clone, Default)]
struct TaskInput {
    from_task: String,
    output: String,
    dest_path: String,
}

// =============================================================================
// TYPED SECRET REFERENCES
// =============================================================================

/// Source of a secret value.
#[derive(Clone, Debug)]
pub enum SecretSource {
    /// Read from environment variable
    Env,
    /// Read from file
    File,
    /// Read from HashiCorp Vault
    Vault,
}

/// A typed reference to a secret with its source.
///
/// # Example
/// ```rust,ignore
/// use sykli::{Pipeline, SecretRef};
///
/// let mut p = Pipeline::new();
/// p.task("deploy")
///     .run("./deploy.sh")
///     .secret_from("TOKEN", SecretRef::from_env("GITHUB_TOKEN"))
///     .secret_from("DB_PASS", SecretRef::from_vault("secret/data/db#password"));
/// ```
#[derive(Clone, Debug)]
pub struct SecretRef {
    /// Environment variable name in the task
    pub name: String,
    /// Where the secret comes from
    pub source: SecretSource,
    /// Source-specific key (env var name, file path, or vault path)
    pub key: String,
}

impl SecretRef {
    /// Creates a secret reference that reads from an environment variable.
    ///
    /// # Panics
    /// Panics if env_var is empty.
    pub fn from_env(env_var: &str) -> Self {
        if env_var.is_empty() {
            panic!("SecretRef::from_env() requires a non-empty environment variable name");
        }
        SecretRef {
            name: String::new(),
            source: SecretSource::Env,
            key: env_var.to_string(),
        }
    }

    /// Creates a secret reference that reads from a file.
    ///
    /// # Panics
    /// Panics if path is empty.
    pub fn from_file(path: &str) -> Self {
        if path.is_empty() {
            panic!("SecretRef::from_file() requires a non-empty file path");
        }
        SecretRef {
            name: String::new(),
            source: SecretSource::File,
            key: path.to_string(),
        }
    }

    /// Creates a secret reference that reads from HashiCorp Vault.
    /// The path format is "path/to/secret#field".
    ///
    /// # Panics
    /// Panics if path doesn't contain '#' separator (required format: "path#field").
    pub fn from_vault(path: &str) -> Self {
        if !path.contains('#') {
            panic!("SecretRef::from_vault() requires 'path#field' format (e.g., 'secret/data/db#password')");
        }
        SecretRef {
            name: String::new(),
            source: SecretSource::Vault,
            key: path.to_string(),
        }
    }
}

// =============================================================================
// AI-NATIVE TYPES
// =============================================================================

/// Task criticality for AI prioritization.
#[derive(Clone, Debug, Default, PartialEq)]
pub enum Criticality {
    /// High priority task
    High,
    /// Medium priority task
    #[default]
    Medium,
    /// Low priority task
    Low,
}

/// What AI should do when a task fails.
#[derive(Clone, Debug, Default, PartialEq)]
pub enum OnFailAction {
    /// AI should analyze the failure
    #[default]
    Analyze,
    /// AI should retry with modifications
    Retry,
    /// AI can skip without analysis
    Skip,
}

/// How AI should select this task for execution.
#[derive(Clone, Debug, Default, PartialEq)]
pub enum SelectMode {
    /// Only run if covers changed files
    Smart,
    /// Always run regardless of changes
    #[default]
    Always,
    /// Only run when explicitly requested
    Manual,
}

/// Semantic metadata for AI understanding of the task.
#[derive(Clone, Default)]
struct Semantic {
    covers: Vec<String>,
    intent: Option<String>,
    criticality: Option<Criticality>,
}

/// AI behavioral hooks.
#[derive(Clone, Default)]
struct AiHooks {
    on_fail: Option<OnFailAction>,
    select: Option<SelectMode>,
}

// =============================================================================
// CONDITION BUILDER (Type-safe conditions)
// =============================================================================

/// A type-safe condition for when a task should run.
///
/// Use the builder functions to create conditions:
///
/// # Example
/// ```rust,ignore
/// use sykli::{Pipeline, Condition};
///
/// let mut p = Pipeline::new();
/// p.task("deploy")
///     .run("kubectl apply")
///     .when_cond(Condition::branch("main").or(Condition::tag("v*")));
///
/// p.task("test")
///     .run("cargo test")
///     .when_cond(Condition::negate(Condition::branch("wip/*")));
/// ```
#[derive(Clone, Default, Debug)]
pub struct Condition {
    expr: String,
}

impl Condition {
    /// Creates a condition that matches a branch name or pattern.
    /// Supports glob patterns like "feature/*".
    ///
    /// # Panics
    /// Panics if pattern is empty. Use `Condition::default()` for an always-true condition.
    pub fn branch(pattern: &str) -> Self {
        if pattern.is_empty() {
            panic!("Condition::branch() requires a non-empty pattern. Use Condition::default() for always-true.");
        }
        if pattern.contains('*') {
            Condition {
                expr: format!("branch matches '{}'", pattern),
            }
        } else {
            Condition {
                expr: format!("branch == '{}'", pattern),
            }
        }
    }

    /// Creates a condition that matches a tag name or pattern.
    /// Supports glob patterns like "v*".
    pub fn tag(pattern: &str) -> Self {
        if pattern.is_empty() {
            Condition {
                expr: "tag != ''".to_string(),
            }
        } else if pattern.contains('*') {
            Condition {
                expr: format!("tag matches '{}'", pattern),
            }
        } else {
            Condition {
                expr: format!("tag == '{}'", pattern),
            }
        }
    }

    /// Creates a condition that matches when any tag is present.
    pub fn has_tag() -> Self {
        Condition {
            expr: "tag != ''".to_string(),
        }
    }

    /// Creates a condition that matches a CI event type.
    pub fn event(event_type: &str) -> Self {
        Condition {
            expr: format!("event == '{}'", event_type),
        }
    }

    /// Creates a condition that matches when running in CI.
    pub fn in_ci() -> Self {
        Condition {
            expr: "ci == true".to_string(),
        }
    }

    /// Negates a condition.
    ///
    /// Note: Named `negate` instead of `not` to avoid confusion with `std::ops::Not`.
    pub fn negate(c: Condition) -> Self {
        Condition {
            expr: format!("!({})", c.expr),
        }
    }

    /// Combines conditions with OR logic.
    pub fn or(self, other: Condition) -> Self {
        Condition {
            expr: format!("({}) || ({})", self.expr, other.expr),
        }
    }

    /// Combines conditions with AND logic.
    pub fn and(self, other: Condition) -> Self {
        Condition {
            expr: format!("({}) && ({})", self.expr, other.expr),
        }
    }
}

impl std::fmt::Display for Condition {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.expr)
    }
}

#[derive(Clone, Default)]
struct TaskData {
    name: String,
    command: String,
    container: Option<String>,
    workdir: Option<String>,
    env: HashMap<String, String>,
    mounts: Vec<Mount>,
    inputs: Vec<String>,         // v1-style file patterns
    task_inputs: Vec<TaskInput>, // v2-style inputs from other tasks
    outputs: HashMap<String, String>,
    depends_on: Vec<String>,
    condition: Option<String>,
    when_cond: Option<Condition>, // Type-safe condition (alternative to string)
    secrets: Vec<String>,         // v1-style secret names
    secret_refs: Vec<SecretRef>,  // v2-style typed secret references
    matrix: HashMap<String, Vec<String>>,
    services: Vec<Service>,
    // Robustness features
    retry: Option<u32>,   // Number of retries on failure
    timeout: Option<u32>, // Timeout in seconds
    // K8s options
    k8s_options: Option<K8sOptions>,
    k8s_raw: Option<String>, // Raw K8s JSON for advanced options
    // Per-task target override
    target_name: Option<String>,
    // Node placement - required node labels
    requires: Vec<String>,
    // AI-native fields
    semantic: Semantic,
    ai_hooks: AiHooks,
}

impl<'a> Task<'a> {
    /// Applies a template's configuration to this task.
    ///
    /// Template settings are applied first, then task-specific settings override them.
    #[must_use]
    pub fn from(self, tmpl: &Template) -> Self {
        let task = &mut self.pipeline.tasks[self.index];

        // Apply template settings (task settings will override these)
        if task.container.is_none() {
            task.container = tmpl.container.clone();
        }
        if task.workdir.is_none() {
            task.workdir = tmpl.workdir.clone();
        }

        // Merge env: template first, then task overrides
        for (k, v) in &tmpl.env {
            if !task.env.contains_key(k) {
                task.env.insert(k.clone(), v.clone());
            }
        }

        // Prepend template mounts
        let mut new_mounts = tmpl.mounts.clone();
        new_mounts.append(&mut task.mounts);
        task.mounts = new_mounts;

        self
    }

    /// Returns the name of this task.
    pub fn name(&self) -> String {
        self.pipeline.tasks[self.index].name.clone()
    }

    /// Sets the command for this task.
    ///
    /// # Panics
    /// Panics if `cmd` is empty.
    #[must_use]
    pub fn run(self, cmd: &str) -> Self {
        assert!(!cmd.is_empty(), "command cannot be empty");
        self.pipeline.tasks[self.index].command = cmd.to_string();
        self
    }

    /// Sets the container image for this task.
    ///
    /// # Panics
    /// Panics if `image` is empty.
    #[must_use]
    pub fn container(self, image: &str) -> Self {
        assert!(!image.is_empty(), "container image cannot be empty");
        self.pipeline.tasks[self.index].container = Some(image.to_string());
        self
    }

    /// Mounts a directory into the container.
    ///
    /// # Panics
    /// Panics if `path` is empty or not absolute (must start with `/`).
    #[must_use]
    pub fn mount(self, dir: &Directory, path: &str) -> Self {
        assert!(!path.is_empty(), "container mount path cannot be empty");
        assert!(
            path.starts_with('/'),
            "container mount path must be absolute (start with /)"
        );
        self.pipeline.tasks[self.index].mounts.push(Mount {
            resource: dir.id(),
            path: path.to_string(),
            mount_type: "directory".to_string(),
        });
        self
    }

    /// Mounts a cache volume into the container.
    ///
    /// # Panics
    /// Panics if `path` is empty or not absolute (must start with `/`).
    #[must_use]
    pub fn mount_cache(self, cache: &CacheVolume, path: &str) -> Self {
        assert!(!path.is_empty(), "container mount path cannot be empty");
        assert!(
            path.starts_with('/'),
            "container mount path must be absolute (start with /)"
        );
        self.pipeline.tasks[self.index].mounts.push(Mount {
            resource: cache.id(),
            path: path.to_string(),
            mount_type: "cache".to_string(),
        });
        self
    }

    /// Mounts the current working directory to `/work` and sets workdir.
    /// This is a convenience method that combines mount + workdir for the common case.
    #[must_use]
    pub fn mount_cwd(self) -> Self {
        self.pipeline.tasks[self.index].mounts.push(Mount {
            resource: "src:.".to_string(),
            path: "/work".to_string(),
            mount_type: "directory".to_string(),
        });
        self.pipeline.tasks[self.index].workdir = Some("/work".to_string());
        self
    }

    /// Mounts the current working directory to a custom path and sets workdir.
    ///
    /// # Panics
    /// Panics if `path` is empty or not absolute (must start with `/`).
    #[must_use]
    pub fn mount_cwd_at(self, path: &str) -> Self {
        assert!(!path.is_empty(), "container mount path cannot be empty");
        assert!(
            path.starts_with('/'),
            "container mount path must be absolute (start with /)"
        );
        self.pipeline.tasks[self.index].mounts.push(Mount {
            resource: "src:.".to_string(),
            path: path.to_string(),
            mount_type: "directory".to_string(),
        });
        self.pipeline.tasks[self.index].workdir = Some(path.to_string());
        self
    }

    /// Sets the working directory inside the container.
    ///
    /// # Panics
    /// Panics if `path` is empty or not absolute (must start with `/`).
    #[must_use]
    pub fn workdir(self, path: &str) -> Self {
        assert!(
            !path.is_empty(),
            "container working directory cannot be empty"
        );
        assert!(
            path.starts_with('/'),
            "container working directory must be absolute (start with /)"
        );
        self.pipeline.tasks[self.index].workdir = Some(path.to_string());
        self
    }

    /// Sets an environment variable.
    ///
    /// # Panics
    /// Panics if `key` is empty.
    #[must_use]
    pub fn env(self, key: &str, value: &str) -> Self {
        assert!(!key.is_empty(), "environment variable key cannot be empty");
        self.pipeline.tasks[self.index]
            .env
            .insert(key.to_string(), value.to_string());
        self
    }

    /// Sets input file patterns for caching.
    #[must_use]
    pub fn inputs(self, patterns: &[&str]) -> Self {
        self.pipeline.tasks[self.index]
            .inputs
            .extend(patterns.iter().map(|s| (*s).to_string()));
        self
    }

    /// Sets a named output path.
    ///
    /// # Panics
    /// Panics if `name` or `path` is empty.
    #[must_use]
    pub fn output(self, name: &str, path: &str) -> Self {
        assert!(!name.is_empty(), "output name cannot be empty");
        assert!(!path.is_empty(), "output path cannot be empty");
        self.pipeline.tasks[self.index]
            .outputs
            .insert(name.to_string(), path.to_string());
        self
    }

    /// Declares that this task needs an artifact from another task's output.
    ///
    /// This automatically adds a dependency on the source task.
    ///
    /// # Arguments
    /// * `from_task` - Name of the task that produces the artifact
    /// * `output_name` - Name of the output from that task
    /// * `dest_path` - Path where the artifact should be available in this task
    ///
    /// # Panics
    /// Panics if any argument is empty.
    #[must_use]
    pub fn input_from(self, from_task: &str, output_name: &str, dest_path: &str) -> Self {
        assert!(
            !from_task.is_empty(),
            "input_from: from_task cannot be empty"
        );
        assert!(
            !output_name.is_empty(),
            "input_from: output_name cannot be empty"
        );
        assert!(
            !dest_path.is_empty(),
            "input_from: dest_path cannot be empty"
        );

        let task = &mut self.pipeline.tasks[self.index];

        // Add the task input
        task.task_inputs.push(TaskInput {
            from_task: from_task.to_string(),
            output: output_name.to_string(),
            dest_path: dest_path.to_string(),
        });

        // Auto-add dependency if not already present
        if !task.depends_on.contains(&from_task.to_string()) {
            task.depends_on.push(from_task.to_string());
        }

        self
    }

    /// Sets output paths (for backward compatibility).
    ///
    /// # Panics
    /// Panics if any path is empty.
    #[must_use]
    pub fn outputs(self, paths: &[&str]) -> Self {
        for (i, path) in paths.iter().enumerate() {
            assert!(!path.is_empty(), "output path cannot be empty");
            self.pipeline.tasks[self.index]
                .outputs
                .insert(format!("output_{i}"), (*path).to_string());
        }
        self
    }

    /// Sets a single dependency - this task runs after the named task.
    ///
    /// This is a convenience method matching the Go SDK's `After(task)` signature.
    #[must_use]
    pub fn after_one(self, task: &str) -> Self {
        self.pipeline.tasks[self.index]
            .depends_on
            .push(task.to_string());
        self
    }

    /// Sets dependencies - this task runs after the named tasks.
    #[must_use]
    pub fn after(self, tasks: &[&str]) -> Self {
        self.pipeline.tasks[self.index]
            .depends_on
            .extend(tasks.iter().map(|s| (*s).to_string()));
        self
    }

    /// Sets dependencies on all tasks in a TaskGroup.
    ///
    /// # Example
    /// ```rust,ignore
    /// let tests = p.matrix("versions", &["1.21", "1.22"], |p, v| {
    ///     p.task(&format!("test-{}", v)).run("go test");
    /// });
    /// p.task("deploy").after_group(&tests).run("deploy");
    /// ```
    #[must_use]
    pub fn after_group(self, group: &TaskGroup) -> Self {
        self.pipeline.tasks[self.index]
            .depends_on
            .extend(group.task_names.clone());
        self
    }

    /// Sets a condition for when this task should run.
    ///
    /// The condition is evaluated at runtime based on CI context variables:
    /// - `branch == 'main'` - run only on main branch
    /// - `branch != 'main'` - run on all branches except main
    /// - `tag != ''` - run only when a tag is present
    /// - `event == 'push'` - run only on push events
    /// - `ci == true` - run only in CI environment
    ///
    /// # Example
    /// ```rust
    /// use sykli::Pipeline;
    ///
    /// let mut p = Pipeline::new();
    /// p.task("deploy")
    ///     .run("./deploy.sh")
    ///     .when("branch == 'main'");
    /// ```
    ///
    /// # Panics
    /// Panics if `condition` is empty.
    #[must_use]
    pub fn when(self, condition: &str) -> Self {
        assert!(!condition.is_empty(), "condition cannot be empty");
        self.pipeline.tasks[self.index].condition = Some(condition.to_string());
        self
    }

    /// Declares that this task requires a secret environment variable.
    ///
    /// The secret should be provided by the CI environment (e.g., GitHub Actions secrets).
    /// The executor will validate that the secret is present before running the task.
    ///
    /// # Example
    /// ```rust
    /// use sykli::Pipeline;
    ///
    /// let mut p = Pipeline::new();
    /// p.task("deploy")
    ///     .run("./deploy.sh")
    ///     .secret("GITHUB_TOKEN")
    ///     .secret("NPM_TOKEN");
    /// ```
    ///
    /// # Panics
    /// Panics if `name` is empty.
    #[must_use]
    pub fn secret(self, name: &str) -> Self {
        assert!(!name.is_empty(), "secret name cannot be empty");
        self.pipeline.tasks[self.index]
            .secrets
            .push(name.to_string());
        self
    }

    /// Declares multiple secrets that this task requires.
    ///
    /// # Example
    /// ```rust
    /// use sykli::Pipeline;
    ///
    /// let mut p = Pipeline::new();
    /// p.task("deploy")
    ///     .run("./deploy.sh")
    ///     .secrets(&["GITHUB_TOKEN", "NPM_TOKEN", "AWS_KEY"]);
    /// ```
    ///
    /// # Panics
    /// Panics if any secret name is empty.
    #[must_use]
    pub fn secrets(self, names: &[&str]) -> Self {
        for name in names {
            assert!(!name.is_empty(), "secret name cannot be empty");
        }
        self.pipeline.tasks[self.index]
            .secrets
            .extend(names.iter().map(|s| (*s).to_string()));
        self
    }

    /// Declares node labels that must be present for this task to run.
    ///
    /// Tasks with requires will only run on nodes that have all specified labels.
    ///
    /// # Example
    /// ```rust
    /// use sykli::Pipeline;
    ///
    /// let mut p = Pipeline::new();
    /// p.task("train")
    ///     .run("python train.py")
    ///     .requires(&["gpu", "docker"]);
    ///
    /// p.task("build")
    ///     .run("docker build .")
    ///     .requires(&["docker"]);
    /// ```
    ///
    /// # Panics
    /// Panics if any label is empty.
    #[must_use]
    pub fn requires(self, labels: &[&str]) -> Self {
        for label in labels {
            assert!(!label.is_empty(), "label cannot be empty");
        }
        self.pipeline.tasks[self.index]
            .requires
            .extend(labels.iter().map(|s| (*s).to_string()));
        self
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // AI-NATIVE METHODS
    // ─────────────────────────────────────────────────────────────────────────────

    /// Sets file patterns this task tests or affects (for smart selection).
    #[must_use]
    pub fn covers(self, patterns: &[&str]) -> Self {
        self.pipeline.tasks[self.index]
            .semantic
            .covers
            .extend(patterns.iter().map(|s| (*s).to_string()));
        self
    }

    /// Sets a description of what this task does (for AI context).
    #[must_use]
    pub fn intent(self, description: &str) -> Self {
        self.pipeline.tasks[self.index].semantic.intent = Some(description.to_string());
        self
    }

    /// Marks this task as high-criticality.
    #[must_use]
    pub fn critical(self) -> Self {
        self.pipeline.tasks[self.index].semantic.criticality = Some(Criticality::High);
        self
    }

    /// Sets the criticality level.
    #[must_use]
    pub fn set_criticality(self, level: Criticality) -> Self {
        self.pipeline.tasks[self.index].semantic.criticality = Some(level);
        self
    }

    /// Sets what AI should do when this task fails.
    #[must_use]
    pub fn on_fail(self, action: OnFailAction) -> Self {
        self.pipeline.tasks[self.index].ai_hooks.on_fail = Some(action);
        self
    }

    /// Sets how AI should select this task for execution.
    #[must_use]
    pub fn select_mode(self, mode: SelectMode) -> Self {
        self.pipeline.tasks[self.index].ai_hooks.select = Some(mode);
        self
    }

    /// Enables smart task selection based on covers patterns.
    #[must_use]
    pub fn smart(self) -> Self {
        self.pipeline.tasks[self.index].ai_hooks.select = Some(SelectMode::Smart);
        self
    }

    /// Declares a typed secret reference with explicit source.
    ///
    /// This provides better DX than plain secret names by making the source explicit.
    ///
    /// # Example
    /// ```rust,ignore
    /// use sykli::{Pipeline, SecretRef};
    ///
    /// let mut p = Pipeline::new();
    /// p.task("deploy")
    ///     .run("./deploy.sh")
    ///     .secret_from("GITHUB_TOKEN", SecretRef::from_env("GH_TOKEN"))
    ///     .secret_from("DB_PASSWORD", SecretRef::from_vault("secret/data/db#password"));
    /// ```
    ///
    /// # Panics
    /// Panics if `name` or `ref.key` is empty.
    #[must_use]
    pub fn secret_from(self, name: &str, secret_ref: SecretRef) -> Self {
        assert!(!name.is_empty(), "secret name cannot be empty");
        assert!(!secret_ref.key.is_empty(), "secret key cannot be empty");
        let mut sr = secret_ref;
        sr.name = name.to_string();
        self.pipeline.tasks[self.index].secret_refs.push(sr);
        self
    }

    /// Sets a type-safe condition for when this task should run.
    ///
    /// This is an alternative to `when()` that catches errors at compile time.
    ///
    /// # Example
    /// ```rust,ignore
    /// use sykli::{Pipeline, Condition};
    ///
    /// let mut p = Pipeline::new();
    /// p.task("deploy")
    ///     .run("kubectl apply")
    ///     .when_cond(Condition::branch("main").or(Condition::tag("v*")));
    /// ```
    #[must_use]
    pub fn when_cond(self, c: Condition) -> Self {
        self.pipeline.tasks[self.index].when_cond = Some(c);
        self
    }

    /// Sets the target for this specific task, overriding the pipeline default.
    ///
    /// This enables hybrid pipelines where different tasks run on different targets.
    ///
    /// # Example
    /// ```rust,ignore
    /// use sykli::Pipeline;
    ///
    /// let mut p = Pipeline::new();
    /// p.task("test").run("cargo test").target("local");
    /// p.task("deploy").run("kubectl apply").target("k8s");
    /// ```
    ///
    /// # Panics
    /// Panics if `name` is empty.
    #[must_use]
    pub fn target(self, name: &str) -> Self {
        assert!(!name.is_empty(), "target name cannot be empty");
        self.pipeline.tasks[self.index].target_name = Some(name.to_string());
        self
    }

    /// Adds a matrix dimension for this task.
    ///
    /// Matrix builds run the task multiple times with different parameter combinations.
    /// Each dimension's values are exposed as environment variables.
    ///
    /// # Example
    /// ```rust
    /// use sykli::Pipeline;
    ///
    /// let mut p = Pipeline::new();
    /// p.task("test")
    ///     .run("cargo test")
    ///     .matrix("rust_version", &["1.70", "1.75", "1.80"])
    ///     .matrix("os", &["ubuntu", "macos"]);
    /// // This creates 6 task variants (3 versions × 2 OS)
    /// ```
    ///
    /// # Panics
    /// Panics if `key` or `values` is empty.
    #[must_use]
    pub fn matrix(self, key: &str, values: &[&str]) -> Self {
        assert!(!key.is_empty(), "matrix key cannot be empty");
        assert!(!values.is_empty(), "matrix values cannot be empty");
        self.pipeline.tasks[self.index].matrix.insert(
            key.to_string(),
            values.iter().map(|s| (*s).to_string()).collect(),
        );
        self
    }

    /// Adds a service container that runs alongside this task.
    ///
    /// Services are background containers (like databases) that run during task execution.
    /// The service is accessible via its name as hostname.
    ///
    /// # Example
    /// ```rust
    /// use sykli::Pipeline;
    ///
    /// let mut p = Pipeline::new();
    /// p.task("test")
    ///     .run("cargo test")
    ///     .service("postgres:15", "db")
    ///     .service("redis:7", "cache");
    /// // postgres available at hostname "db", redis at "cache"
    /// ```
    ///
    /// # Panics
    /// Panics if `image` or `name` is empty.
    #[must_use]
    pub fn service(self, image: &str, name: &str) -> Self {
        assert!(!image.is_empty(), "service image cannot be empty");
        assert!(!name.is_empty(), "service name cannot be empty");
        self.pipeline.tasks[self.index].services.push(Service {
            image: image.to_string(),
            name: name.to_string(),
        });
        self
    }

    /// Sets the number of retries on failure.
    ///
    /// If the task fails, it will be retried up to `count` times before being marked as failed.
    ///
    /// # Example
    /// ```rust
    /// use sykli::Pipeline;
    ///
    /// let mut p = Pipeline::new();
    /// p.task("flaky-test")
    ///     .run("cargo test -- --include-ignored")
    ///     .retry(3);  // Retry up to 3 times on failure
    /// ```
    #[must_use]
    pub fn retry(self, count: u32) -> Self {
        debug!(task = %self.pipeline.tasks[self.index].name, retry = count, "setting retry");
        self.pipeline.tasks[self.index].retry = Some(count);
        self
    }

    /// Sets the timeout for this task in seconds.
    ///
    /// If the task doesn't complete within the timeout, it will be killed and marked as failed.
    /// Default timeout is 300 seconds (5 minutes).
    ///
    /// # Example
    /// ```rust
    /// use sykli::Pipeline;
    ///
    /// let mut p = Pipeline::new();
    /// p.task("long-build")
    ///     .run("cargo build --release")
    ///     .timeout(600);  // 10 minute timeout
    /// ```
    ///
    /// # Panics
    /// Panics if `seconds` is 0.
    #[must_use]
    pub fn timeout(self, seconds: u32) -> Self {
        assert!(seconds > 0, "timeout must be greater than 0");
        debug!(task = %self.pipeline.tasks[self.index].name, timeout = seconds, "setting timeout");
        self.pipeline.tasks[self.index].timeout = Some(seconds);
        self
    }

    /// Sets Kubernetes-specific options for this task.
    ///
    /// These options are only used when running with a K8s target.
    /// If pipeline-level K8s defaults are set, task options will be merged
    /// with task values overriding defaults.
    ///
    /// # Example
    /// ```rust,ignore
    /// use sykli::{Pipeline, K8sOptions, K8sResources};
    ///
    /// let mut p = Pipeline::new();
    /// p.task("build")
    ///     .run("cargo build")
    ///     .k8s(K8sOptions {
    ///         resources: K8sResources {
    ///             memory: Some("4Gi".into()),
    ///             cpu: Some("2".into()),
    ///             ..Default::default()
    ///         },
    ///         ..Default::default()
    ///     });
    /// ```
    #[must_use]
    pub fn k8s(self, opts: K8sOptions) -> Self {
        debug!(task = %self.pipeline.tasks[self.index].name, "setting k8s options");
        self.pipeline.tasks[self.index].k8s_options = Some(opts);
        self
    }

    /// Adds raw Kubernetes configuration as JSON.
    ///
    /// Use this for advanced options not covered by `K8sOptions` (tolerations, affinity, etc.).
    /// The JSON is passed directly to the executor and merged with K8sOptions.
    /// K8sOptions fields take precedence over k8s_raw for overlapping settings.
    ///
    /// # Example
    /// ```rust,ignore
    /// // GPU node with toleration
    /// p.task("train")
    ///     .k8s(K8sOptions { memory: Some("32Gi".into()), gpu: Some(1), ..Default::default() })
    ///     .k8s_raw(r#"{"nodeSelector": {"gpu": "true"}, "tolerations": [{"key": "gpu", "effect": "NoSchedule"}]}"#);
    /// ```
    pub fn k8s_raw(self, json_config: &str) -> Self {
        debug!(task = %self.pipeline.tasks[self.index].name, "setting k8s raw JSON");
        self.pipeline.tasks[self.index].k8s_raw = Some(json_config.to_string());
        self
    }
}

// =============================================================================
// EXPLAIN CONTEXT
// =============================================================================

/// Context for evaluating conditions during explain/dry-run.
#[derive(Default)]
pub struct ExplainContext {
    /// Current branch name
    pub branch: String,
    /// Current tag (empty if none)
    pub tag: String,
    /// CI event type (push, pull_request, etc.)
    pub event: String,
    /// Whether running in CI environment
    pub ci: bool,
}

// =============================================================================
// TASK GROUP
// =============================================================================

/// A group of tasks that can be used as a dependency.
/// Created by `matrix()` and can be passed to `after()` or `chain()`.
#[derive(Clone, Debug)]
pub struct TaskGroup {
    /// Name of the group (for identification)
    pub name: String,
    /// Names of tasks in this group
    pub task_names: Vec<String>,
}

impl TaskGroup {
    /// Creates a new task group.
    #[must_use]
    pub fn new(name: impl Into<String>, task_names: Vec<String>) -> Self {
        TaskGroup {
            name: name.into(),
            task_names,
        }
    }

    /// Returns the task names in this group.
    #[must_use]
    pub fn names(&self) -> &[String] {
        &self.task_names
    }
}

// =============================================================================
// PIPELINE
// =============================================================================

/// A CI pipeline with tasks and resources.
pub struct Pipeline {
    tasks: Vec<TaskData>,
    dirs: Vec<Directory>,
    caches: Vec<CacheVolume>,
    k8s_defaults: Option<K8sOptions>,
}

impl Pipeline {
    /// Creates a new pipeline.
    #[must_use]
    pub fn new() -> Self {
        Pipeline {
            tasks: Vec::new(),
            dirs: Vec::new(),
            caches: Vec::new(),
            k8s_defaults: None,
        }
    }

    /// Creates a new pipeline with K8s defaults.
    ///
    /// All tasks inherit these settings unless they override them.
    ///
    /// # Example
    /// ```rust,ignore
    /// use sykli::{Pipeline, K8sOptions, K8sResources};
    ///
    /// let mut p = Pipeline::with_k8s_defaults(K8sOptions {
    ///     namespace: Some("ci-jobs".into()),
    ///     resources: K8sResources {
    ///         memory: Some("2Gi".into()),
    ///         ..Default::default()
    ///     },
    ///     ..Default::default()
    /// });
    ///
    /// p.task("test").run("go test");     // inherits defaults
    /// p.task("heavy").k8s(K8sOptions {   // overrides memory
    ///     resources: K8sResources { memory: Some("32Gi".into()), ..Default::default() },
    ///     ..Default::default()
    /// }).run("heavy-job");
    /// ```
    #[must_use]
    pub fn with_k8s_defaults(k8s_defaults: K8sOptions) -> Self {
        Pipeline {
            tasks: Vec::new(),
            dirs: Vec::new(),
            caches: Vec::new(),
            k8s_defaults: Some(k8s_defaults),
        }
    }

    /// Creates a directory resource.
    ///
    /// # Panics
    /// Panics if `path` is empty.
    pub fn dir(&mut self, path: &str) -> Directory {
        assert!(!path.is_empty(), "directory path cannot be empty");
        let dir = Directory {
            path: path.to_string(),
            globs: Vec::new(),
        };
        self.dirs.push(dir.clone());
        dir
    }

    /// Creates a named cache volume.
    ///
    /// # Panics
    /// Panics if `name` is empty.
    pub fn cache(&mut self, name: &str) -> CacheVolume {
        assert!(!name.is_empty(), "cache name cannot be empty");
        let cache = CacheVolume {
            name: name.to_string(),
        };
        self.caches.push(cache.clone());
        cache
    }

    /// Creates a new task with the given name.
    ///
    /// # Panics
    /// Panics if `name` is empty or if a task with the same name already exists.
    pub fn task(&mut self, name: &str) -> Task<'_> {
        assert!(!name.is_empty(), "task name cannot be empty");
        assert!(
            !self.tasks.iter().any(|t| t.name == name),
            "task {name:?} already exists"
        );
        self.tasks.push(TaskData {
            name: name.to_string(),
            ..Default::default()
        });
        let index = self.tasks.len() - 1;
        Task {
            pipeline: self,
            index,
        }
    }

    /// Returns a Rust preset builder.
    pub fn rust(&mut self) -> RustPreset<'_> {
        RustPreset { pipeline: self }
    }

    /// Creates a sequential dependency chain between tasks.
    ///
    /// Each task in the chain depends on the previous one: a → b → c
    ///
    /// # Example
    /// ```rust
    /// use sykli::Pipeline;
    ///
    /// let mut p = Pipeline::new();
    /// p.task("a").run("echo a");
    /// p.task("b").run("echo b");
    /// p.task("c").run("echo c");
    /// p.chain(&["a", "b", "c"]); // b depends on a, c depends on b
    /// ```
    ///
    /// # Panics
    /// Panics if any task name doesn't exist.
    pub fn chain(&mut self, task_names: &[&str]) {
        for window in task_names.windows(2) {
            let prev = window[0];
            let curr = window[1];

            // Find the current task and add dependency
            let task = self
                .tasks
                .iter_mut()
                .find(|t| t.name == curr)
                .unwrap_or_else(|| panic!("task {:?} not found", curr));

            // Only add the dependency if it doesn't already exist to avoid duplicates.
            if !task.depends_on.iter().any(|d| d == prev) {
                task.depends_on.push(prev.to_string());
            }
        }
    }

    /// Creates a TaskGroup from existing tasks (for parallel dependencies).
    ///
    /// This is a convenience method to create a named group of tasks that can be
    /// used as a dependency. The tasks must already exist in the pipeline.
    ///
    /// # Example
    /// ```rust
    /// use sykli::Pipeline;
    ///
    /// let mut p = Pipeline::new();
    /// p.task("lint").run("cargo clippy");
    /// p.task("test").run("cargo test");
    ///
    /// // Create parallel group from existing tasks
    /// let checks = p.parallel("checks", &["lint", "test"]);
    ///
    /// // Build depends on the parallel group
    /// p.task("build").after_group(&checks).run("cargo build");
    /// ```
    ///
    /// # Panics
    /// Panics if any task name doesn't exist in the pipeline.
    #[must_use]
    pub fn parallel(&self, name: &str, task_names: &[&str]) -> TaskGroup {
        // Validate all tasks exist
        for &task_name in task_names {
            if !self.tasks.iter().any(|t| t.name == task_name) {
                panic!("task {:?} not found in pipeline", task_name);
            }
        }

        TaskGroup::new(name, task_names.iter().map(|s| (*s).to_string()).collect())
    }

    /// Creates tasks for each value in the matrix, returning a TaskGroup.
    ///
    /// # Example
    /// ```rust,ignore
    /// let mut p = Pipeline::new();
    /// let tests = p.matrix("go-versions", &["1.21", "1.22", "1.23"], |p, version| {
    ///     p.task(&format!("test-go-{}", version))
    ///         .container(&format!("golang:{}", version))
    ///         .mount_cwd()
    ///         .run("go test ./...");
    /// });
    /// // Use the group as a dependency
    /// p.task("deploy").after_group(&tests).run("deploy");
    /// ```
    pub fn matrix<F>(&mut self, name: &str, values: &[&str], mut generator: F) -> TaskGroup
    where
        F: FnMut(&mut Pipeline, &str),
    {
        assert!(!values.is_empty(), "matrix: values must not be empty");
        let start_len = self.tasks.len();

        for v in values {
            generator(self, v);
        }

        // Collect names of newly created tasks
        let task_names: Vec<String> = self.tasks[start_len..]
            .iter()
            .map(|t| t.name.clone())
            .collect();

        TaskGroup::new(name, task_names)
    }

    // =========================================================================
    // EXPLAIN (Dry-run mode)
    // =========================================================================

    /// Context for evaluating conditions during explain.
    /// Pass None to use empty defaults.
    pub fn explain(&self, ctx: Option<&ExplainContext>) {
        self.explain_to(&mut io::stdout(), ctx);
    }

    /// Writes the execution plan to the given writer.
    pub fn explain_to<W: Write>(&self, w: &mut W, ctx: Option<&ExplainContext>) {
        let default_ctx = ExplainContext::default();
        let ctx = ctx.unwrap_or(&default_ctx);

        // Topological sort
        let sorted = self.topological_sort();

        writeln!(w, "Pipeline Execution Plan").ok();
        writeln!(w, "=======================").ok();

        for (i, t) in sorted.iter().enumerate() {
            // Build task header
            let mut header = format!("{}. {}", i + 1, t.name);

            // Add dependencies
            if !t.depends_on.is_empty() {
                header.push_str(&format!(" (after: {})", t.depends_on.join(", ")));
            }

            // Add target override
            if let Some(ref target) = t.target_name {
                header.push_str(&format!(" [target: {}]", target));
            }

            // Check if task would be skipped
            let condition = t
                .when_cond
                .as_ref()
                .map(|c| c.to_string())
                .or_else(|| t.condition.clone());
            if let Some(ref cond) = condition {
                if let Some(reason) = self.would_skip(cond, ctx) {
                    header.push_str(&format!(" [SKIPPED: {}]", reason));
                }
            }

            writeln!(w, "{}", header).ok();
            writeln!(w, "   Command: {}", t.command).ok();

            if let Some(ref cond) = condition {
                writeln!(w, "   Condition: {}", cond).ok();
            }

            if !t.secret_refs.is_empty() {
                let secrets: Vec<_> = t
                    .secret_refs
                    .iter()
                    .map(|sr| {
                        let source = match sr.source {
                            SecretSource::Env => "env",
                            SecretSource::File => "file",
                            SecretSource::Vault => "vault",
                        };
                        format!("{} ({}:{})", sr.name, source, sr.key)
                    })
                    .collect();
                writeln!(w, "   Secrets: {}", secrets.join(", ")).ok();
            } else if !t.secrets.is_empty() {
                writeln!(w, "   Secrets: {}", t.secrets.join(", ")).ok();
            }

            writeln!(w).ok();
        }
    }

    /// Check if a task would be skipped given the context.
    fn would_skip(&self, condition: &str, ctx: &ExplainContext) -> Option<String> {
        let condition = condition.trim();

        // branch == 'value'
        if condition.starts_with("branch == '") {
            let expected = condition
                .strip_prefix("branch == '")
                .and_then(|s| s.strip_suffix("'"))
                .unwrap_or("");
            if ctx.branch != expected {
                return Some(format!("branch is '{}', not '{}'", ctx.branch, expected));
            }
        }

        // branch != 'value'
        if condition.starts_with("branch != '") {
            let excluded = condition
                .strip_prefix("branch != '")
                .and_then(|s| s.strip_suffix("'"))
                .unwrap_or("");
            if ctx.branch == excluded {
                return Some(format!("branch is '{}'", ctx.branch));
            }
        }

        // tag != '' (has tag)
        if condition == "tag != ''" && ctx.tag.is_empty() {
            return Some("no tag present".to_string());
        }

        // ci == true
        if condition == "ci == true" && !ctx.ci {
            return Some("not running in CI".to_string());
        }

        None
    }

    /// Topological sort of tasks.
    fn topological_sort(&self) -> Vec<&TaskData> {
        // Build in-degree map
        let mut in_degree: HashMap<&str, usize> = HashMap::new();
        for t in &self.tasks {
            in_degree.entry(&t.name).or_insert(0);
            for _ in &t.depends_on {
                *in_degree.entry(&t.name).or_insert(0) += 1;
            }
        }

        // Kahn's algorithm
        let mut queue: Vec<&str> = in_degree
            .iter()
            .filter(|(_, &d)| d == 0)
            .map(|(n, _)| *n)
            .collect();

        let task_map: HashMap<&str, &TaskData> =
            self.tasks.iter().map(|t| (t.name.as_str(), t)).collect();
        let mut sorted = Vec::new();

        while let Some(name) = queue.pop() {
            if let Some(t) = task_map.get(name) {
                sorted.push(*t);

                // Decrease in-degree of dependents
                for other in &self.tasks {
                    for dep in &other.depends_on {
                        if dep == name {
                            if let Some(d) = in_degree.get_mut(other.name.as_str()) {
                                *d -= 1;
                                if *d == 0 {
                                    queue.push(&other.name);
                                }
                            }
                        }
                    }
                }
            }
        }

        sorted
    }

    /// Emits the pipeline as JSON to stdout if `--emit` flag is present.
    ///
    /// This method checks for `--emit` in command line arguments and if found,
    /// writes the pipeline JSON to stdout and exits the process with code 0.
    /// If emission fails, exits with code 1.
    ///
    /// **Note:** This method exits the process and does not return. For non-exiting
    /// behavior, use [`Pipeline::emit_to`] directly.
    pub fn emit(&self) {
        if env::args().any(|arg| arg == "--emit") {
            if let Err(e) = self.emit_to(&mut io::stdout()) {
                eprintln!("error: {}", e);
                std::process::exit(1);
            }
            std::process::exit(0);
        }
    }

    /// Always emits the pipeline as JSON to stdout and exits.
    ///
    /// Unlike [`Pipeline::emit`], this method always writes the JSON output
    /// regardless of command line arguments. This matches the Go SDK's `MustEmit()`.
    ///
    /// **Note:** This method exits the process and does not return.
    pub fn force_emit(&self) {
        if let Err(e) = self.emit_to(&mut io::stdout()) {
            eprintln!("error: {}", e);
            std::process::exit(1);
        }
        std::process::exit(0);
    }

    /// Writes the pipeline JSON to the given writer.
    pub fn emit_to<W: Write>(&self, w: &mut W) -> io::Result<()> {
        // Validate
        let task_names: Vec<_> = self.tasks.iter().map(|t| t.name.as_str()).collect();
        for t in &self.tasks {
            if t.command.is_empty() {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("task {:?} has no command", t.name),
                ));
            }
            for dep in &t.depends_on {
                if !task_names.contains(&dep.as_str()) {
                    let suggestion = suggest_task_name(dep, &task_names);
                    let msg = if let Some(suggested) = suggestion {
                        format!(
                            "task {:?} depends on unknown task {:?} (did you mean {:?}?)",
                            t.name, dep, suggested
                        )
                    } else {
                        format!("task {:?} depends on unknown task {:?}", t.name, dep)
                    };
                    return Err(io::Error::new(io::ErrorKind::InvalidData, msg));
                }
            }
        }

        // Cycle detection
        if let Some(cycle) = self.detect_cycle() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("dependency cycle detected: {}", cycle.join(" -> ")),
            ));
        }

        // Validate K8s options (merge defaults first, then validate)
        for t in &self.tasks {
            let merged = match (&self.k8s_defaults, &t.k8s_options) {
                (None, None) => None,
                (Some(defaults), None) => Some(defaults.clone()),
                (None, Some(task)) => Some(task.clone()),
                (Some(defaults), Some(task)) => Some(K8sOptions::merge(defaults, task)),
            };
            if let Some(ref opts) = merged {
                let errors = opts.validate();
                if !errors.is_empty() {
                    tracing::error!(task = %t.name, error = %errors[0], "K8s validation failed");
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        format!("task {:?}: {}", t.name, errors[0]),
                    ));
                }
            }
        }

        // Detect version based on usage
        let has_v2_features = !self.dirs.is_empty()
            || !self.caches.is_empty()
            || self
                .tasks
                .iter()
                .any(|t| t.container.is_some() || !t.mounts.is_empty());

        let version = if has_v2_features { "2" } else { "1" };

        // Build output
        let output = JsonPipeline {
            version: version.to_string(),
            resources: if has_v2_features {
                let mut resources = HashMap::new();
                for d in &self.dirs {
                    resources.insert(
                        d.id(),
                        JsonResource {
                            type_: "directory".to_string(),
                            path: Some(d.path.clone()),
                            name: None,
                            globs: if d.globs.is_empty() {
                                None
                            } else {
                                Some(d.globs.clone())
                            },
                        },
                    );
                }
                for c in &self.caches {
                    resources.insert(
                        c.id(),
                        JsonResource {
                            type_: "cache".to_string(),
                            path: None,
                            name: Some(c.name.clone()),
                            globs: None,
                        },
                    );
                }
                // Only include resources if non-empty (matches Go SDK behavior)
                if resources.is_empty() {
                    None
                } else {
                    Some(resources)
                }
            } else {
                None
            },
            tasks: self
                .tasks
                .iter()
                .map(|t| JsonTask {
                    name: t.name.clone(),
                    command: t.command.clone(),
                    container: t.container.clone(),
                    workdir: t.workdir.clone(),
                    env: if t.env.is_empty() {
                        None
                    } else {
                        Some(t.env.clone())
                    },
                    mounts: if t.mounts.is_empty() {
                        None
                    } else {
                        Some(
                            t.mounts
                                .iter()
                                .map(|m| JsonMount {
                                    resource: m.resource.clone(),
                                    path: m.path.clone(),
                                    type_: m.mount_type.clone(),
                                })
                                .collect(),
                        )
                    },
                    inputs: if t.inputs.is_empty() {
                        None
                    } else {
                        Some(t.inputs.clone())
                    },
                    task_inputs: if t.task_inputs.is_empty() {
                        None
                    } else {
                        Some(
                            t.task_inputs
                                .iter()
                                .map(|ti| JsonTaskInput {
                                    from_task: ti.from_task.clone(),
                                    output: ti.output.clone(),
                                    dest: ti.dest_path.clone(),
                                })
                                .collect(),
                        )
                    },
                    outputs: if t.outputs.is_empty() {
                        None
                    } else {
                        Some(t.outputs.clone())
                    },
                    depends_on: if t.depends_on.is_empty() {
                        None
                    } else {
                        Some(t.depends_on.clone())
                    },
                    condition: t
                        .when_cond
                        .as_ref()
                        .map(|c| c.to_string())
                        .or_else(|| t.condition.clone()),
                    secrets: if t.secrets.is_empty() {
                        None
                    } else {
                        Some(t.secrets.clone())
                    },
                    secret_refs: if t.secret_refs.is_empty() {
                        None
                    } else {
                        Some(
                            t.secret_refs
                                .iter()
                                .map(|sr| JsonSecretRef {
                                    name: sr.name.clone(),
                                    source: match sr.source {
                                        SecretSource::Env => "env".to_string(),
                                        SecretSource::File => "file".to_string(),
                                        SecretSource::Vault => "vault".to_string(),
                                    },
                                    key: sr.key.clone(),
                                })
                                .collect(),
                        )
                    },
                    matrix: if t.matrix.is_empty() {
                        None
                    } else {
                        Some(t.matrix.clone())
                    },
                    services: if t.services.is_empty() {
                        None
                    } else {
                        Some(
                            t.services
                                .iter()
                                .map(|s| JsonService {
                                    image: s.image.clone(),
                                    name: s.name.clone(),
                                })
                                .collect(),
                        )
                    },
                    retry: t.retry,
                    timeout: t.timeout,
                    target: t.target_name.clone(),
                    k8s: {
                        // Merge pipeline defaults with task options
                        let merged = match (&self.k8s_defaults, &t.k8s_options) {
                            (None, None) => None,
                            (Some(defaults), None) => Some(defaults.clone()),
                            (None, Some(task)) => Some(task.clone()),
                            (Some(defaults), Some(task)) => Some(K8sOptions::merge(defaults, task)),
                        };
                        // Include k8s options if we have either structured opts or raw JSON
                        if merged.as_ref().is_some_and(|o| !o.is_empty()) || t.k8s_raw.is_some() {
                            Some(convert_k8s_options(
                                merged.as_ref().unwrap_or(&K8sOptions::default()),
                                t.k8s_raw.as_ref(),
                            ))
                        } else {
                            None
                        }
                    },
                    requires: if t.requires.is_empty() {
                        None
                    } else {
                        Some(t.requires.clone())
                    },
                    semantic: {
                        let s = &t.semantic;
                        if s.covers.is_empty() && s.intent.is_none() && s.criticality.is_none() {
                            None
                        } else {
                            Some(JsonSemantic {
                                covers: if s.covers.is_empty() { None } else { Some(s.covers.clone()) },
                                intent: s.intent.clone(),
                                criticality: s.criticality.as_ref().map(|c| match c {
                                    Criticality::High => "high".to_string(),
                                    Criticality::Medium => "medium".to_string(),
                                    Criticality::Low => "low".to_string(),
                                }),
                            })
                        }
                    },
                    ai_hooks: {
                        let h = &t.ai_hooks;
                        if h.on_fail.is_none() && h.select.is_none() {
                            None
                        } else {
                            Some(JsonAiHooks {
                                on_fail: h.on_fail.as_ref().map(|a| match a {
                                    OnFailAction::Analyze => "analyze".to_string(),
                                    OnFailAction::Retry => "retry".to_string(),
                                    OnFailAction::Skip => "skip".to_string(),
                                }),
                                select: h.select.as_ref().map(|s| match s {
                                    SelectMode::Smart => "smart".to_string(),
                                    SelectMode::Always => "always".to_string(),
                                    SelectMode::Manual => "manual".to_string(),
                                }),
                            })
                        }
                    },
                })
                .collect(),
        };

        serde_json::to_writer(&mut *w, &output)?;
        writeln!(w)?;
        Ok(())
    }
}

impl Default for Pipeline {
    fn default() -> Self {
        Self::new()
    }
}

// =============================================================================
// RUST PRESET
// =============================================================================

/// Convenience methods for Rust projects.
pub struct RustPreset<'a> {
    pipeline: &'a mut Pipeline,
}

impl<'a> RustPreset<'a> {
    /// Standard input patterns for Rust projects.
    pub fn inputs() -> Vec<&'static str> {
        vec!["**/*.rs", "Cargo.toml", "Cargo.lock"]
    }

    /// Adds a "cargo test" task.
    pub fn test(self) -> Task<'a> {
        self.pipeline
            .task("test")
            .run("cargo test")
            .inputs(&Self::inputs())
    }

    /// Adds a "cargo clippy" task.
    pub fn lint(self) -> Task<'a> {
        self.pipeline
            .task("lint")
            .run("cargo clippy -- -D warnings")
            .inputs(&Self::inputs())
    }

    /// Adds a "cargo build --release" task.
    pub fn build(self, output: &str) -> Task<'a> {
        self.pipeline
            .task("build")
            .run("cargo build --release")
            .inputs(&Self::inputs())
            .outputs(&[output])
    }
}

// =============================================================================
// CYCLE DETECTION
// =============================================================================

/// Color for DFS cycle detection
#[derive(Clone, Copy, PartialEq)]
enum Color {
    White, // unvisited
    Gray,  // currently visiting (in recursion stack)
    Black, // completely processed
}

impl Pipeline {
    /// Detects cycles in the task dependency graph using DFS.
    /// Returns the cycle path if found, None otherwise.
    fn detect_cycle(&self) -> Option<Vec<String>> {
        // Build adjacency map: task name -> dependencies
        let deps: HashMap<&str, Vec<&str>> = self
            .tasks
            .iter()
            .map(|t| {
                (
                    t.name.as_str(),
                    t.depends_on.iter().map(|s| s.as_str()).collect(),
                )
            })
            .collect();

        let mut color: HashMap<&str, Color> = self
            .tasks
            .iter()
            .map(|t| (t.name.as_str(), Color::White))
            .collect();

        let mut parent: HashMap<&str, &str> = HashMap::new();

        // DFS from each unvisited node
        for task in &self.tasks {
            if color[task.name.as_str()] == Color::White {
                if let Some(cycle) =
                    self.dfs_detect_cycle(task.name.as_str(), &deps, &mut color, &mut parent)
                {
                    return Some(cycle);
                }
            }
        }

        None
    }

    /// Performs DFS and returns cycle path if found.
    fn dfs_detect_cycle<'a>(
        &self,
        node: &'a str,
        deps: &HashMap<&'a str, Vec<&'a str>>,
        color: &mut HashMap<&'a str, Color>,
        parent: &mut HashMap<&'a str, &'a str>,
    ) -> Option<Vec<String>> {
        color.insert(node, Color::Gray);

        if let Some(node_deps) = deps.get(node) {
            for &dep in node_deps {
                if color.get(dep) == Some(&Color::Gray) {
                    // Found a cycle - reconstruct the path
                    return Some(self.reconstruct_cycle(node, dep, parent));
                }
                if color.get(dep) == Some(&Color::White) {
                    parent.insert(dep, node);
                    if let Some(cycle) = self.dfs_detect_cycle(dep, deps, color, parent) {
                        return Some(cycle);
                    }
                }
            }
        }

        color.insert(node, Color::Black);
        None
    }

    /// Reconstructs the cycle path from the detected back edge.
    fn reconstruct_cycle(&self, from: &str, to: &str, parent: &HashMap<&str, &str>) -> Vec<String> {
        // Cycle: to -> ... -> from -> to
        let mut cycle = vec![to.to_string()];
        let mut current = from;
        while current != to {
            cycle.insert(0, current.to_string());
            current = parent.get(current).unwrap_or(&to);
        }
        cycle.insert(0, to.to_string()); // Close the cycle
        cycle
    }
}

// =============================================================================
// JSON SERIALIZATION
// =============================================================================

#[derive(Serialize)]
struct JsonPipeline {
    version: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    resources: Option<HashMap<String, JsonResource>>,
    tasks: Vec<JsonTask>,
}

#[derive(Serialize)]
struct JsonResource {
    #[serde(rename = "type")]
    type_: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    globs: Option<Vec<String>>,
}

#[derive(Serialize)]
struct JsonTaskInput {
    from_task: String,
    output: String,
    dest: String,
}

#[derive(Serialize)]
struct JsonSecretRef {
    name: String,
    source: String,
    key: String,
}

#[derive(Serialize)]
struct JsonSemantic {
    #[serde(skip_serializing_if = "Option::is_none")]
    covers: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    intent: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    criticality: Option<String>,
}

#[derive(Serialize)]
struct JsonAiHooks {
    #[serde(skip_serializing_if = "Option::is_none")]
    on_fail: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    select: Option<String>,
}

#[derive(Serialize)]
struct JsonTask {
    name: String,
    command: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    container: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    workdir: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    env: Option<HashMap<String, String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    mounts: Option<Vec<JsonMount>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    inputs: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    task_inputs: Option<Vec<JsonTaskInput>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    outputs: Option<HashMap<String, String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    depends_on: Option<Vec<String>>,
    #[serde(rename = "when", skip_serializing_if = "Option::is_none")]
    condition: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    secrets: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    secret_refs: Option<Vec<JsonSecretRef>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    matrix: Option<HashMap<String, Vec<String>>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    services: Option<Vec<JsonService>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    retry: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    timeout: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    target: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    k8s: Option<JsonK8sOptions>,
    #[serde(skip_serializing_if = "Option::is_none")]
    requires: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    semantic: Option<JsonSemantic>,
    #[serde(skip_serializing_if = "Option::is_none")]
    ai_hooks: Option<JsonAiHooks>,
}

/// Minimal K8s options for JSON serialization.
/// For advanced options, use k8s_raw which is passed through as-is.
#[derive(Serialize)]
struct JsonK8sOptions {
    #[serde(skip_serializing_if = "Option::is_none")]
    memory: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    cpu: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    gpu: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    raw: Option<String>,
}

fn convert_k8s_options(opts: &K8sOptions, raw: Option<&String>) -> JsonK8sOptions {
    JsonK8sOptions {
        memory: opts.memory.clone(),
        cpu: opts.cpu.clone(),
        gpu: opts.gpu,
        raw: raw.cloned(),
    }
}

#[derive(Serialize)]
struct JsonMount {
    resource: String,
    path: String,
    #[serde(rename = "type")]
    type_: String,
}

#[derive(Serialize)]
struct JsonService {
    image: String,
    name: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_basic_task() {
        let mut p = Pipeline::new();
        p.task("test").run("cargo test");

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        assert_eq!(json["version"], "1");
        assert_eq!(json["tasks"][0]["name"], "test");
        assert_eq!(json["tasks"][0]["command"], "cargo test");
    }

    #[test]
    fn test_task_with_dependencies() {
        let mut p = Pipeline::new();
        p.task("test").run("cargo test");
        p.task("build").run("cargo build").after(&["test"]);

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        assert_eq!(json["tasks"][1]["depends_on"][0], "test");
    }

    #[test]
    fn test_container_task() {
        let mut p = Pipeline::new();
        let src = p.dir(".");

        p.task("test")
            .container("rust:1.75")
            .mount(&src, "/src")
            .workdir("/src")
            .run("cargo test");

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        assert_eq!(json["version"], "2");
        assert_eq!(json["tasks"][0]["container"], "rust:1.75");
        assert_eq!(json["resources"]["src:."]["type"], "directory");
    }

    #[test]
    fn test_cache_mount() {
        let mut p = Pipeline::new();
        let cache = p.cache("cargo-registry");

        p.task("build")
            .container("rust:1.75")
            .mount_cache(&cache, "/usr/local/cargo/registry")
            .run("cargo build");

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        assert_eq!(json["resources"]["cargo-registry"]["type"], "cache");
        assert_eq!(json["tasks"][0]["mounts"][0]["type"], "cache");
    }

    #[test]
    fn test_rust_preset() {
        let mut p = Pipeline::new();
        p.rust().test();
        p.rust().build("target/release/app").after(&["test"]);

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        assert_eq!(json["tasks"][0]["name"], "test");
        assert_eq!(json["tasks"][0]["command"], "cargo test");
        assert_eq!(json["tasks"][1]["name"], "build");
    }

    #[test]
    #[should_panic(expected = "task name cannot be empty")]
    fn test_empty_task_name_panics() {
        let mut p = Pipeline::new();
        p.task("");
    }

    #[test]
    #[should_panic(expected = "already exists")]
    fn test_duplicate_task_panics() {
        let mut p = Pipeline::new();
        p.task("test").run("cargo test");
        p.task("test").run("cargo test");
    }

    #[test]
    fn test_unknown_dependency_fails() {
        let mut p = Pipeline::new();
        p.task("build").run("cargo build").after(&["nonexistent"]);

        let mut buf = Vec::new();
        let result = p.emit_to(&mut buf);
        assert!(result.is_err());
    }

    #[test]
    fn test_env_in_json() {
        let mut p = Pipeline::new();
        p.task("build")
            .run("cargo build")
            .env("RUST_BACKTRACE", "1")
            .env("CARGO_TERM_COLOR", "always");

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        assert_eq!(json["tasks"][0]["env"]["RUST_BACKTRACE"], "1");
        assert_eq!(json["tasks"][0]["env"]["CARGO_TERM_COLOR"], "always");
    }

    #[test]
    fn test_inputs_in_json() {
        let mut p = Pipeline::new();
        p.task("test")
            .run("cargo test")
            .inputs(&["**/*.rs", "Cargo.toml"]);

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        let inputs = json["tasks"][0]["inputs"].as_array().unwrap();
        assert_eq!(inputs.len(), 2);
        assert_eq!(inputs[0], "**/*.rs");
        assert_eq!(inputs[1], "Cargo.toml");
    }

    #[test]
    fn test_directory_glob() {
        // Test that glob() works on Directory (returns updated Directory)
        let mut p = Pipeline::new();
        let src = p.dir(".");
        let src_with_glob = src.glob(&["**/*.rs", "Cargo.toml"]);

        // The glob patterns are stored on the returned Directory
        assert_eq!(src_with_glob.globs.len(), 2);
        assert_eq!(src_with_glob.globs[0], "**/*.rs");
        assert_eq!(src_with_glob.globs[1], "Cargo.toml");
    }

    #[test]
    #[should_panic(expected = "container image cannot be empty")]
    fn test_empty_container_panics() {
        let mut p = Pipeline::new();
        p.task("test").container("");
    }

    #[test]
    #[should_panic(expected = "container working directory must be absolute")]
    fn test_relative_workdir_panics() {
        let mut p = Pipeline::new();
        p.task("test").workdir("relative/path");
    }

    #[test]
    #[should_panic(expected = "output name cannot be empty")]
    fn test_empty_output_name_panics() {
        let mut p = Pipeline::new();
        p.task("build").run("cargo build").output("", "./app");
    }

    #[test]
    #[should_panic(expected = "output path cannot be empty")]
    fn test_empty_output_path_panics() {
        let mut p = Pipeline::new();
        p.task("build").run("cargo build").output("binary", "");
    }

    #[test]
    #[should_panic(expected = "environment variable key cannot be empty")]
    fn test_empty_env_key_panics() {
        let mut p = Pipeline::new();
        p.task("test").env("", "value");
    }

    #[test]
    #[should_panic(expected = "container mount path must be absolute")]
    fn test_relative_mount_path_panics() {
        let mut p = Pipeline::new();
        let src = p.dir(".");
        p.task("test").mount(&src, "relative");
    }

    #[test]
    #[should_panic(expected = "container mount path cannot be empty")]
    fn test_empty_mount_path_panics() {
        let mut p = Pipeline::new();
        let src = p.dir(".");
        p.task("test").mount(&src, "");
    }

    #[test]
    #[should_panic(expected = "container working directory cannot be empty")]
    fn test_empty_workdir_panics() {
        let mut p = Pipeline::new();
        p.task("test").workdir("");
    }

    #[test]
    fn test_rust_preset_inputs() {
        let mut p = Pipeline::new();
        p.rust().test();

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        let inputs = json["tasks"][0]["inputs"].as_array().unwrap();
        assert!(inputs.contains(&serde_json::json!("**/*.rs")));
        assert!(inputs.contains(&serde_json::json!("Cargo.toml")));
        assert!(inputs.contains(&serde_json::json!("Cargo.lock")));
    }

    #[test]
    fn test_rust_preset_lint_command() {
        let mut p = Pipeline::new();
        p.rust().lint();

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        assert_eq!(json["tasks"][0]["command"], "cargo clippy -- -D warnings");
    }

    #[test]
    fn test_rust_preset_build_output() {
        let mut p = Pipeline::new();
        p.rust().build("target/release/myapp");

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        assert_eq!(
            json["tasks"][0]["outputs"]["output_0"],
            "target/release/myapp"
        );
    }

    #[test]
    fn test_version_v1_simple_tasks() {
        let mut p = Pipeline::new();
        p.task("test").run("cargo test");
        p.task("build").run("cargo build");

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        assert_eq!(json["version"], "1");
        assert!(json["resources"].is_null());
    }

    #[test]
    fn test_version_v2_with_dir() {
        let mut p = Pipeline::new();
        let _src = p.dir(".");
        p.task("test").run("cargo test");

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        assert_eq!(json["version"], "2");
    }

    #[test]
    fn test_version_v2_with_cache() {
        let mut p = Pipeline::new();
        let _cache = p.cache("test-cache");
        p.task("test").run("cargo test");

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        assert_eq!(json["version"], "2");
    }

    #[test]
    fn test_version_v2_with_container() {
        let mut p = Pipeline::new();
        p.task("test").container("rust:1.75").run("cargo test");

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        assert_eq!(json["version"], "2");
    }

    #[test]
    fn test_when_branch_condition() {
        let mut p = Pipeline::new();
        p.task("deploy").run("./deploy.sh").when("branch == 'main'");

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        assert_eq!(json["tasks"][0]["when"], "branch == 'main'");
    }

    #[test]
    fn test_when_tag_condition() {
        let mut p = Pipeline::new();
        p.task("release").run("./release.sh").when("tag != ''");

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        assert_eq!(json["tasks"][0]["when"], "tag != ''");
    }

    #[test]
    fn test_when_not_set() {
        let mut p = Pipeline::new();
        p.task("test").run("cargo test");

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        assert!(json["tasks"][0]["when"].is_null());
    }

    #[test]
    #[should_panic(expected = "condition cannot be empty")]
    fn test_when_empty_panics() {
        let mut p = Pipeline::new();
        p.task("test").run("cargo test").when("");
    }

    #[test]
    fn test_when_with_other_options() {
        let mut p = Pipeline::new();
        p.task("test").run("cargo test");
        p.task("build").run("cargo build");
        p.task("deploy")
            .run("./deploy.sh")
            .after(&["test", "build"])
            .when("branch == 'main'");

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        assert_eq!(json["tasks"][2]["when"], "branch == 'main'");
        assert_eq!(json["tasks"][2]["depends_on"][0], "test");
        assert_eq!(json["tasks"][2]["depends_on"][1], "build");
    }

    // ----- SECRET TESTS -----

    #[test]
    fn test_secret_single() {
        let mut p = Pipeline::new();
        p.task("deploy").run("./deploy.sh").secret("GITHUB_TOKEN");

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        let secrets = json["tasks"][0]["secrets"].as_array().unwrap();
        assert_eq!(secrets.len(), 1);
        assert_eq!(secrets[0], "GITHUB_TOKEN");
    }

    #[test]
    fn test_secret_multiple() {
        let mut p = Pipeline::new();
        p.task("deploy")
            .run("./deploy.sh")
            .secret("GITHUB_TOKEN")
            .secret("NPM_TOKEN")
            .secret("AWS_ACCESS_KEY");

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        let secrets = json["tasks"][0]["secrets"].as_array().unwrap();
        assert_eq!(secrets.len(), 3);
        assert!(secrets.contains(&serde_json::json!("GITHUB_TOKEN")));
        assert!(secrets.contains(&serde_json::json!("NPM_TOKEN")));
        assert!(secrets.contains(&serde_json::json!("AWS_ACCESS_KEY")));
    }

    #[test]
    fn test_secret_not_set() {
        let mut p = Pipeline::new();
        p.task("test").run("cargo test");

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        assert!(json["tasks"][0]["secrets"].is_null());
    }

    #[test]
    #[should_panic(expected = "secret name cannot be empty")]
    fn test_secret_empty_panics() {
        let mut p = Pipeline::new();
        p.task("deploy").run("./deploy.sh").secret("");
    }

    #[test]
    fn test_secrets_method() {
        let mut p = Pipeline::new();
        p.task("deploy")
            .run("./deploy.sh")
            .secrets(&["GITHUB_TOKEN", "NPM_TOKEN"]);

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        let secrets = json["tasks"][0]["secrets"].as_array().unwrap();
        assert_eq!(secrets.len(), 2);
    }

    // ----- MATRIX TESTS -----

    #[test]
    fn test_matrix_single_dimension() {
        let mut p = Pipeline::new();
        p.task("test")
            .run("cargo test")
            .matrix("rust_version", &["1.70", "1.75", "1.80"]);

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        let matrix = json["tasks"][0]["matrix"].as_object().unwrap();
        assert_eq!(matrix.len(), 1);
        let versions = matrix["rust_version"].as_array().unwrap();
        assert_eq!(versions.len(), 3);
        assert_eq!(versions[0], "1.70");
    }

    #[test]
    fn test_matrix_multiple_dimensions() {
        let mut p = Pipeline::new();
        p.task("test")
            .run("cargo test")
            .matrix("rust_version", &["1.70", "1.75"])
            .matrix("os", &["ubuntu", "macos"]);

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        let matrix = json["tasks"][0]["matrix"].as_object().unwrap();
        assert_eq!(matrix.len(), 2);
        assert!(matrix.contains_key("rust_version"));
        assert!(matrix.contains_key("os"));
    }

    #[test]
    fn test_matrix_not_set() {
        let mut p = Pipeline::new();
        p.task("test").run("cargo test");

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        assert!(json["tasks"][0]["matrix"].is_null());
    }

    #[test]
    #[should_panic(expected = "matrix key cannot be empty")]
    fn test_matrix_empty_key_panics() {
        let mut p = Pipeline::new();
        p.task("test").run("cargo test").matrix("", &["value"]);
    }

    #[test]
    #[should_panic(expected = "matrix values cannot be empty")]
    fn test_matrix_empty_values_panics() {
        let mut p = Pipeline::new();
        p.task("test").run("cargo test").matrix("key", &[]);
    }

    // ----- SERVICE TESTS -----

    #[test]
    fn test_service_single() {
        let mut p = Pipeline::new();
        p.task("test")
            .run("cargo test")
            .service("postgres:15", "db");

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        let services = json["tasks"][0]["services"].as_array().unwrap();
        assert_eq!(services.len(), 1);
        assert_eq!(services[0]["image"], "postgres:15");
        assert_eq!(services[0]["name"], "db");
    }

    #[test]
    fn test_service_multiple() {
        let mut p = Pipeline::new();
        p.task("test")
            .run("cargo test")
            .service("postgres:15", "db")
            .service("redis:7", "cache");

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        let services = json["tasks"][0]["services"].as_array().unwrap();
        assert_eq!(services.len(), 2);
    }

    #[test]
    fn test_service_not_set() {
        let mut p = Pipeline::new();
        p.task("test").run("cargo test");

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        assert!(json["tasks"][0]["services"].is_null());
    }

    #[test]
    #[should_panic(expected = "service image cannot be empty")]
    fn test_service_empty_image_panics() {
        let mut p = Pipeline::new();
        p.task("test").run("cargo test").service("", "db");
    }

    #[test]
    #[should_panic(expected = "service name cannot be empty")]
    fn test_service_empty_name_panics() {
        let mut p = Pipeline::new();
        p.task("test").run("cargo test").service("postgres:15", "");
    }

    // ----- RETRY TESTS -----

    #[test]
    fn test_retry_in_json() {
        let mut p = Pipeline::new();
        p.task("flaky").run("./flaky.sh").retry(3);

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        assert_eq!(json["tasks"][0]["retry"], 3);
    }

    #[test]
    fn test_retry_not_set() {
        let mut p = Pipeline::new();
        p.task("test").run("cargo test");

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        assert!(json["tasks"][0]["retry"].is_null());
    }

    // ----- TIMEOUT TESTS -----

    #[test]
    fn test_timeout_in_json() {
        let mut p = Pipeline::new();
        p.task("long").run("./long-running.sh").timeout(600);

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        assert_eq!(json["tasks"][0]["timeout"], 600);
    }

    #[test]
    fn test_timeout_not_set() {
        let mut p = Pipeline::new();
        p.task("test").run("cargo test");

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        assert!(json["tasks"][0]["timeout"].is_null());
    }

    #[test]
    #[should_panic(expected = "timeout must be greater than 0")]
    fn test_timeout_zero_panics() {
        let mut p = Pipeline::new();
        p.task("test").run("cargo test").timeout(0);
    }

    #[test]
    fn test_retry_and_timeout_combined() {
        let mut p = Pipeline::new();
        p.task("flaky").run("./flaky.sh").retry(2).timeout(120);

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        assert_eq!(json["tasks"][0]["retry"], 2);
        assert_eq!(json["tasks"][0]["timeout"], 120);
    }

    // ----- CYCLE DETECTION TESTS -----

    #[test]
    fn test_cycle_self_reference() {
        // A task that depends on itself: A -> A
        let mut p = Pipeline::new();
        p.task("build").run("cargo build").after(&["build"]);

        let mut buf = Vec::new();
        let result = p.emit_to(&mut buf);
        assert!(result.is_err());
        let err = result.unwrap_err().to_string();
        assert!(err.contains("cycle"), "expected cycle error, got: {}", err);
    }

    #[test]
    fn test_cycle_direct_two_tasks() {
        // Direct cycle between two tasks: A -> B -> A
        let mut p = Pipeline::new();
        p.task("a").run("echo a").after(&["b"]);
        p.task("b").run("echo b").after(&["a"]);

        let mut buf = Vec::new();
        let result = p.emit_to(&mut buf);
        assert!(result.is_err());
        let err = result.unwrap_err().to_string();
        assert!(err.contains("cycle"), "expected cycle error, got: {}", err);
    }

    #[test]
    fn test_cycle_indirect_three_tasks() {
        // Indirect cycle: A -> B -> C -> A
        let mut p = Pipeline::new();
        p.task("a").run("echo a").after(&["b"]);
        p.task("b").run("echo b").after(&["c"]);
        p.task("c").run("echo c").after(&["a"]);

        let mut buf = Vec::new();
        let result = p.emit_to(&mut buf);
        assert!(result.is_err());
        let err = result.unwrap_err().to_string();
        assert!(err.contains("cycle"), "expected cycle error, got: {}", err);
    }

    #[test]
    fn test_cycle_longer_chain() {
        // Longer cycle: A -> B -> C -> D -> E -> A
        let mut p = Pipeline::new();
        p.task("a").run("echo a").after(&["b"]);
        p.task("b").run("echo b").after(&["c"]);
        p.task("c").run("echo c").after(&["d"]);
        p.task("d").run("echo d").after(&["e"]);
        p.task("e").run("echo e").after(&["a"]);

        let mut buf = Vec::new();
        let result = p.emit_to(&mut buf);
        assert!(result.is_err());
        let err = result.unwrap_err().to_string();
        assert!(err.contains("cycle"), "expected cycle error, got: {}", err);
    }

    #[test]
    fn test_cycle_in_complex_graph() {
        // Complex graph with a cycle hidden among valid dependencies
        let mut p = Pipeline::new();
        p.task("test").run("cargo test");
        p.task("lint").run("cargo clippy");
        p.task("build").run("cargo build").after(&["test", "lint"]);
        p.task("deploy")
            .run("./deploy.sh")
            .after(&["build", "verify"]);
        p.task("verify").run("./verify.sh").after(&["deploy"]);

        let mut buf = Vec::new();
        let result = p.emit_to(&mut buf);
        assert!(result.is_err());
        let err = result.unwrap_err().to_string();
        assert!(err.contains("cycle"), "expected cycle error, got: {}", err);
    }

    #[test]
    fn test_cycle_error_shows_path() {
        // Verify the error message includes the cycle path
        let mut p = Pipeline::new();
        p.task("a").run("echo a").after(&["b"]);
        p.task("b").run("echo b").after(&["a"]);

        let mut buf = Vec::new();
        let result = p.emit_to(&mut buf);
        assert!(result.is_err());
        let err = result.unwrap_err().to_string();
        // Error should mention both tasks in the cycle
        assert!(
            err.contains("a") && err.contains("b"),
            "cycle error should mention tasks in cycle, got: {}",
            err
        );
    }

    #[test]
    fn test_no_cycle_valid_dag() {
        // Valid DAG with no cycles - should succeed
        // build depends on test, lint; deploy depends on build
        let mut p = Pipeline::new();
        p.task("test").run("cargo test");
        p.task("lint").run("cargo clippy");
        p.task("build").run("cargo build").after(&["test", "lint"]);
        p.task("deploy").run("./deploy.sh").after(&["build"]);

        let mut buf = Vec::new();
        let result = p.emit_to(&mut buf);
        assert!(result.is_ok(), "valid DAG should not error: {:?}", result);
    }

    #[test]
    fn test_no_cycle_diamond_pattern() {
        // Diamond pattern: b -> a, c -> a, d -> b, d -> c
        // (b,c depend on a; d depends on b,c; execution: a then b,c then d)
        let mut p = Pipeline::new();
        p.task("a").run("echo a");
        p.task("b").run("echo b").after(&["a"]);
        p.task("c").run("echo c").after(&["a"]);
        p.task("d").run("echo d").after(&["b", "c"]);

        let mut buf = Vec::new();
        let result = p.emit_to(&mut buf);
        assert!(
            result.is_ok(),
            "diamond pattern should not error: {:?}",
            result
        );
    }

    #[test]
    fn test_no_cycle_multiple_roots() {
        // Multiple independent roots converging
        let mut p = Pipeline::new();
        p.task("a").run("echo a");
        p.task("b").run("echo b");
        p.task("c").run("echo c");
        p.task("final").run("echo final").after(&["a", "b", "c"]);

        let mut buf = Vec::new();
        let result = p.emit_to(&mut buf);
        assert!(
            result.is_ok(),
            "multiple roots should not error: {:?}",
            result
        );
    }

    // =============================================================================
    // TEMPLATE TESTS
    // =============================================================================

    #[test]
    fn test_template_basic() {
        let mut p = Pipeline::new();
        let src = p.dir(".");

        // Create template with common config
        let tmpl = Template::new()
            .container("rust:1.75")
            .mount_dir(&src, "/src")
            .workdir("/src");

        // Task inherits from template
        p.task("test").from(&tmpl).run("cargo test");

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        assert_eq!(json["tasks"][0]["container"], "rust:1.75");
        assert_eq!(json["tasks"][0]["workdir"], "/src");
        assert_eq!(json["tasks"][0]["mounts"][0]["path"], "/src");
    }

    #[test]
    fn test_template_with_cache() {
        let mut p = Pipeline::new();
        let src = p.dir(".");
        let cache = p.cache("cargo-registry");

        let tmpl = Template::new()
            .container("rust:1.75")
            .mount_dir(&src, "/src")
            .mount_cache(&cache, "/usr/local/cargo/registry")
            .workdir("/src");

        p.task("test").from(&tmpl).run("cargo test");
        p.task("build").from(&tmpl).run("cargo build");

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        // Both tasks should have 2 mounts
        assert_eq!(json["tasks"][0]["mounts"].as_array().unwrap().len(), 2);
        assert_eq!(json["tasks"][1]["mounts"].as_array().unwrap().len(), 2);
    }

    #[test]
    fn test_template_with_env() {
        let mut p = Pipeline::new();

        let tmpl = Template::new()
            .container("rust:1.75")
            .env("RUST_BACKTRACE", "1")
            .env("CARGO_TERM_COLOR", "always");

        p.task("build").from(&tmpl).run("cargo build");

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        assert_eq!(json["tasks"][0]["env"]["RUST_BACKTRACE"], "1");
        assert_eq!(json["tasks"][0]["env"]["CARGO_TERM_COLOR"], "always");
    }

    #[test]
    fn test_template_override() {
        let mut p = Pipeline::new();

        let tmpl = Template::new()
            .container("rust:1.75")
            .env("FOO", "from-template");

        // Task overrides env
        p.task("test")
            .from(&tmpl)
            .env("FOO", "from-task")
            .run("echo $FOO");

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        // Task-level should override
        assert_eq!(json["tasks"][0]["env"]["FOO"], "from-task");
    }

    #[test]
    fn test_template_multiple_tasks() {
        let mut p = Pipeline::new();
        let src = p.dir(".");

        let rust = Template::new()
            .container("rust:1.75")
            .mount_dir(&src, "/src")
            .workdir("/src");

        p.task("lint").from(&rust).run("cargo clippy");
        p.task("test").from(&rust).run("cargo test");
        p.task("build")
            .from(&rust)
            .run("cargo build")
            .after(&["lint", "test"]);

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        assert_eq!(json["tasks"].as_array().unwrap().len(), 3);
        // All should have same container
        for i in 0..3 {
            assert_eq!(json["tasks"][i]["container"], "rust:1.75");
        }
    }

    // =============================================================================
    // CHAIN TESTS
    // =============================================================================

    #[test]
    fn test_chain_basic() {
        let mut p = Pipeline::new();
        p.task("a").run("echo a");
        p.task("b").run("echo b");
        p.task("c").run("echo c");

        // Chain creates: a → b → c
        p.chain(&["a", "b", "c"]);

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        // a has no deps
        assert!(json["tasks"][0]["depends_on"].is_null());
        // b depends on a
        assert_eq!(json["tasks"][1]["depends_on"][0], "a");
        // c depends on b
        assert_eq!(json["tasks"][2]["depends_on"][0], "b");
    }

    #[test]
    fn test_chain_preserves_existing_deps() {
        let mut p = Pipeline::new();
        p.task("prereq").run("echo prereq");
        p.task("a").run("echo a").after(&["prereq"]); // existing dep
        p.task("b").run("echo b");

        p.chain(&["a", "b"]);

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        // a should still have prereq AND nothing from chain (it's first)
        let a_deps = json["tasks"][1]["depends_on"].as_array().unwrap();
        assert_eq!(a_deps.len(), 1);
        assert_eq!(a_deps[0], "prereq");

        // b should depend on a (from chain)
        assert_eq!(json["tasks"][2]["depends_on"][0], "a");
    }

    #[test]
    fn test_chain_single_task() {
        let mut p = Pipeline::new();
        p.task("only").run("echo only");

        p.chain(&["only"]); // Single task - no deps added

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        assert!(json["tasks"][0]["depends_on"].is_null());
    }

    // =============================================================================
    // PARALLEL GROUP TESTS
    // =============================================================================

    #[test]
    fn test_parallel_as_dependency() {
        let mut p = Pipeline::new();
        p.task("lint").run("cargo clippy");
        p.task("test").run("cargo test");

        // Parallel group: both have no deps themselves
        // Build depends on the group
        let checks = &["lint", "test"];
        p.task("build").run("cargo build").after(checks);

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        // lint and test have no deps
        assert!(json["tasks"][0]["depends_on"].is_null());
        assert!(json["tasks"][1]["depends_on"].is_null());

        // build depends on both
        let build_deps = json["tasks"][2]["depends_on"].as_array().unwrap();
        assert_eq!(build_deps.len(), 2);
    }

    #[test]
    fn test_chain_with_parallel_group() {
        let mut p = Pipeline::new();
        // Parallel checks
        p.task("lint").run("cargo clippy");
        p.task("test").run("cargo test");
        let checks = vec!["lint", "test"];

        // Build after checks
        p.task("build").run("cargo build").after(&checks);

        // Deploy after build
        p.task("deploy").run("./deploy.sh").after(&["build"]);

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        // lint and test parallel (no deps)
        assert!(json["tasks"][0]["depends_on"].is_null());
        assert!(json["tasks"][1]["depends_on"].is_null());

        // build depends on both
        assert_eq!(json["tasks"][2]["depends_on"].as_array().unwrap().len(), 2);

        // deploy depends on build
        assert_eq!(json["tasks"][3]["depends_on"][0], "build");
    }

    // =============================================================================
    // TASK NAME METHOD TEST
    // =============================================================================

    #[test]
    fn test_task_name_method() {
        let mut p = Pipeline::new();
        let name = p.task("my-task").run("echo test").name();
        assert_eq!(name, "my-task");
    }

    // =============================================================================
    // INPUT/OUTPUT BINDING TESTS
    // =============================================================================

    #[test]
    fn test_input_from_basic() {
        let mut p = Pipeline::new();

        // Build produces output
        p.task("build")
            .run("cargo build --release")
            .output("binary", "target/release/app");

        // Package consumes it
        p.task("package")
            .input_from("build", "binary", "/app")
            .run("docker build .");

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        // Check task_inputs
        let inputs = json["tasks"][1]["task_inputs"].as_array().unwrap();
        assert_eq!(inputs.len(), 1);
        assert_eq!(inputs[0]["from_task"], "build");
        assert_eq!(inputs[0]["output"], "binary");
        assert_eq!(inputs[0]["dest"], "/app");
    }

    #[test]
    fn test_input_from_auto_adds_dep() {
        let mut p = Pipeline::new();

        p.task("build").run("cargo build").output("binary", "./app");
        p.task("package")
            .input_from("build", "binary", "/app")
            .run("docker build");

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        // package should depend on build
        let deps = json["tasks"][1]["depends_on"].as_array().unwrap();
        assert_eq!(deps.len(), 1);
        assert_eq!(deps[0], "build");
    }

    #[test]
    fn test_input_from_multiple() {
        let mut p = Pipeline::new();

        p.task("build-linux")
            .run("cargo build")
            .output("binary", "./linux");
        p.task("build-darwin")
            .run("cargo build")
            .output("binary", "./darwin");
        p.task("package")
            .input_from("build-linux", "binary", "/linux")
            .input_from("build-darwin", "binary", "/darwin")
            .run("tar czf release.tar.gz /linux /darwin");

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        let inputs = json["tasks"][2]["task_inputs"].as_array().unwrap();
        assert_eq!(inputs.len(), 2);

        let deps = json["tasks"][2]["depends_on"].as_array().unwrap();
        assert_eq!(deps.len(), 2);
    }

    #[test]
    fn test_input_from_no_duplicate_deps() {
        let mut p = Pipeline::new();

        p.task("build").run("cargo build").output("binary", "./app");
        // Explicit after AND input_from - should not duplicate
        p.task("package")
            .after(&["build"])
            .input_from("build", "binary", "/app")
            .run("docker build");

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        // Should have only one dep, not duplicated
        let deps = json["tasks"][1]["depends_on"].as_array().unwrap();
        assert_eq!(deps.len(), 1);
    }

    // =============================================================================
    // K8S VALIDATION TESTS
    // =============================================================================

    #[test]
    fn test_k8s_validation_valid_memory_formats() {
        let valid = ["512Mi", "4Gi", "1Ti", "256Ki", "1G", "500M", "100"];
        for mem in valid {
            let opts = K8sOptions {
                memory: Some(mem.to_string()),
                ..Default::default()
            };
            let errors = opts.validate();
            assert!(errors.is_empty(), "expected {} to be valid", mem);
        }
    }

    #[test]
    fn test_k8s_validation_invalid_memory_formats() {
        let cases = [
            ("32gb", "did you mean 'Gi'"),
            ("512mb", "did you mean 'Mi'"),
            ("1kb", "did you mean 'Ki'"),
            ("4GB", "did you mean 'Gi'"),
            ("lots", "invalid memory format"),
        ];
        for (mem, expected_hint) in cases {
            let mut p = Pipeline::new();
            p.task("test").run("echo test").k8s(K8sOptions {
                memory: Some(mem.to_string()),
                ..Default::default()
            });
            let mut buf = Vec::new();
            let result = p.emit_to(&mut buf);
            assert!(result.is_err(), "expected {} to fail", mem);
            let err_msg = result.unwrap_err().to_string();
            assert!(
                err_msg.contains(expected_hint),
                "expected error for {} to contain '{}', got: {}",
                mem,
                expected_hint,
                err_msg
            );
        }
    }

    #[test]
    fn test_k8s_validation_valid_cpu_formats() {
        let valid = ["100m", "500m", "1", "2", "0.5", "1.5"];
        for cpu in valid {
            let opts = K8sOptions {
                cpu: Some(cpu.to_string()),
                ..Default::default()
            };
            let errors = opts.validate();
            assert!(errors.is_empty(), "expected {} to be valid", cpu);
        }
    }

    #[test]
    fn test_k8s_validation_invalid_cpu_formats() {
        let cases = ["100cores", "2 cores", "fast"];
        for cpu in cases {
            let mut p = Pipeline::new();
            p.task("test").run("echo test").k8s(K8sOptions {
                cpu: Some(cpu.to_string()),
                ..Default::default()
            });
            let mut buf = Vec::new();
            let result = p.emit_to(&mut buf);
            assert!(result.is_err(), "expected {} to fail", cpu);
        }
    }

    #[test]
    fn test_k8s_gpu() {
        let mut p = Pipeline::new();
        p.task("train")
            .run("python train.py")
            .k8s(K8sOptions {
                memory: Some("32Gi".into()),
                gpu: Some(2),
                ..Default::default()
            });

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        assert_eq!(json["tasks"][0]["k8s"]["memory"], "32Gi");
        assert_eq!(json["tasks"][0]["k8s"]["gpu"], 2);
    }

    #[test]
    fn test_k8s_raw_escape_hatch() {
        // k8s_raw allows advanced options (tolerations, volumes, etc.)
        let mut p = Pipeline::new();
        p.task("gpu-train")
            .run("python train.py")
            .k8s(K8sOptions {
                memory: Some("32Gi".into()),
                gpu: Some(1),
                ..Default::default()
            })
            .k8s_raw(r#"{"nodeSelector": {"gpu": "true"}, "tolerations": [{"key": "gpu", "effect": "NoSchedule"}]}"#);

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        // Structured options
        assert_eq!(json["tasks"][0]["k8s"]["memory"], "32Gi");
        assert_eq!(json["tasks"][0]["k8s"]["gpu"], 1);
        // Raw JSON passed through
        assert!(json["tasks"][0]["k8s"]["raw"].as_str().unwrap().contains("nodeSelector"));
    }

    #[test]
    fn test_k8s_raw_only() {
        // Can use k8s_raw without structured K8sOptions
        let mut p = Pipeline::new();
        p.task("custom")
            .run("echo test")
            .k8s_raw(r#"{"serviceAccount": "my-sa"}"#);

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        assert!(json["tasks"][0]["k8s"]["raw"].as_str().unwrap().contains("serviceAccount"));
    }

    #[test]
    fn test_k8s_validation_with_defaults() {
        // Validation should happen after merging with defaults
        let mut p = Pipeline::with_k8s_defaults(K8sOptions {
            memory: Some("invalid_memory".to_string()),
            ..Default::default()
        });
        p.task("test").run("echo test");

        let mut buf = Vec::new();
        let result = p.emit_to(&mut buf);
        assert!(result.is_err());
        assert!(result
            .unwrap_err()
            .to_string()
            .contains("invalid memory format"));
    }

    // =========================================================================
    // MATRIX BUILD TESTS
    // =========================================================================

    #[test]
    fn test_matrix_basic() {
        let mut p = Pipeline::new();

        let group = p.matrix("go-versions", &["1.21", "1.22", "1.23"], |p, version| {
            p.task(&format!("test-go-{}", version))
                .container(&format!("golang:{}", version))
                .run("go test ./...");
        });

        // Should have 3 task names
        assert_eq!(group.task_names.len(), 3);
        assert_eq!(group.name, "go-versions");

        // Verify task names
        assert!(group.task_names.contains(&"test-go-1.21".to_string()));
        assert!(group.task_names.contains(&"test-go-1.22".to_string()));
        assert!(group.task_names.contains(&"test-go-1.23".to_string()));

        // Should emit successfully
        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();
        let tasks = json["tasks"].as_array().unwrap();
        assert_eq!(tasks.len(), 3);
    }

    #[test]
    #[should_panic(expected = "matrix: values must not be empty")]
    fn test_matrix_empty_panics() {
        let mut p = Pipeline::new();
        p.matrix("empty", &[], |p, v| {
            p.task(&format!("test-{}", v)).run("test");
        });
    }

    #[test]
    fn test_matrix_as_dependency() {
        let mut p = Pipeline::new();

        let tests = p.matrix("tests", &["1.21", "1.22"], |p, version| {
            p.task(&format!("test-{}", version)).run("go test");
        });

        // Another task depends on the entire matrix
        p.task("deploy").after_group(&tests).run("deploy");

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        // Find deploy task
        let tasks = json["tasks"].as_array().unwrap();
        let deploy = tasks.iter().find(|t| t["name"] == "deploy").unwrap();
        let deps = deploy["depends_on"].as_array().unwrap();

        // Should depend on both matrix tasks
        assert_eq!(deps.len(), 2);
    }

    #[test]
    fn test_task_group_new() {
        let group = TaskGroup::new(
            "test-group",
            vec!["task-a".to_string(), "task-b".to_string()],
        );

        assert_eq!(group.name, "test-group");
        assert_eq!(group.names(), &["task-a", "task-b"]);
    }

    #[test]
    fn test_after_group() {
        let mut p = Pipeline::new();

        p.task("a").run("echo a");
        p.task("b").run("echo b");

        let group = TaskGroup::new("prereqs", vec!["a".to_string(), "b".to_string()]);

        p.task("c").after_group(&group).run("echo c");

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        let tasks = json["tasks"].as_array().unwrap();
        let task_c = tasks.iter().find(|t| t["name"] == "c").unwrap();
        let deps = task_c["depends_on"].as_array().unwrap();

        // Should depend on both a and b
        assert_eq!(deps.len(), 2);
        assert!(deps.contains(&serde_json::json!("a")));
        assert!(deps.contains(&serde_json::json!("b")));
    }

    // =============================================================================
    // PARALLEL METHOD TESTS
    // =============================================================================

    #[test]
    fn test_parallel_creates_group() {
        let mut p = Pipeline::new();
        p.task("lint").run("cargo clippy");
        p.task("test").run("cargo test");

        let checks = p.parallel("checks", &["lint", "test"]);

        assert_eq!(checks.name, "checks");
        assert_eq!(checks.names(), &["lint", "test"]);
    }

    #[test]
    fn test_parallel_as_group_dependency() {
        let mut p = Pipeline::new();
        p.task("lint").run("cargo clippy");
        p.task("test").run("cargo test");

        let checks = p.parallel("checks", &["lint", "test"]);

        p.task("build").after_group(&checks).run("cargo build");

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        let tasks = json["tasks"].as_array().unwrap();
        let build = tasks.iter().find(|t| t["name"] == "build").unwrap();
        let deps = build["depends_on"].as_array().unwrap();

        assert_eq!(deps.len(), 2);
        assert!(deps.contains(&serde_json::json!("lint")));
        assert!(deps.contains(&serde_json::json!("test")));
    }

    #[test]
    #[should_panic(expected = "task \"unknown\" not found")]
    fn test_parallel_unknown_task_panics() {
        let mut p = Pipeline::new();
        p.task("lint").run("cargo clippy");

        // "unknown" doesn't exist
        p.parallel("checks", &["lint", "unknown"]);
    }
}
