//! Sykli - CI pipelines defined in Rust instead of YAML
//!
//! # Simple usage
//!
//! ```rust
//! use sykli::Pipeline;
//!
//! fn main() {
//!     let mut p = Pipeline::new();
//!     p.task("test").run("cargo test");
//!     p.task("build").run("cargo build --release").after(&["test"]);
//!     p.emit();
//! }
//! ```
//!
//! # With containers and caching
//!
//! ```rust
//! use sykli::Pipeline;
//!
//! fn main() {
//!     let mut p = Pipeline::new();
//!     let src = p.dir(".");
//!     let cache = p.cache("cargo-registry");
//!
//!     p.task("test")
//!         .container("rust:1.75")
//!         .mount(&src, "/src")
//!         .mount_cache(&cache, "/usr/local/cargo/registry")
//!         .workdir("/src")
//!         .run("cargo test");
//!
//!     p.emit();
//! }
//! ```

use serde::Serialize;
use std::collections::HashMap;
use std::env;
use std::io::{self, Write};
use tracing::debug;

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
// TASK
// =============================================================================

/// A task in the pipeline.
pub struct Task<'a> {
    pipeline: &'a mut Pipeline,
    index: usize,
}

#[derive(Clone, Default)]
struct TaskData {
    name: String,
    command: String,
    container: Option<String>,
    workdir: Option<String>,
    env: HashMap<String, String>,
    mounts: Vec<Mount>,
    inputs: Vec<String>,
    outputs: HashMap<String, String>,
    depends_on: Vec<String>,
    condition: Option<String>,
    secrets: Vec<String>,
    matrix: HashMap<String, Vec<String>>,
    services: Vec<Service>,
    // Robustness features
    retry: Option<u32>,   // Number of retries on failure
    timeout: Option<u32>, // Timeout in seconds
}

impl<'a> Task<'a> {
    /// Sets the command for this task.
    pub fn run(self, cmd: &str) -> Self {
        if cmd.is_empty() {
            panic!("command cannot be empty");
        }
        self.pipeline.tasks[self.index].command = cmd.to_string();
        self
    }

    /// Sets the container image for this task.
    pub fn container(self, image: &str) -> Self {
        if image.is_empty() {
            panic!("container image cannot be empty");
        }
        self.pipeline.tasks[self.index].container = Some(image.to_string());
        self
    }

    /// Mounts a directory into the container.
    pub fn mount(self, dir: &Directory, path: &str) -> Self {
        if path.is_empty() {
            panic!("container mount path cannot be empty");
        }
        if !path.starts_with('/') {
            panic!("container mount path must be absolute (start with /)");
        }
        self.pipeline.tasks[self.index].mounts.push(Mount {
            resource: dir.id(),
            path: path.to_string(),
            mount_type: "directory".to_string(),
        });
        self
    }

    /// Mounts a cache volume into the container.
    pub fn mount_cache(self, cache: &CacheVolume, path: &str) -> Self {
        if path.is_empty() {
            panic!("container mount path cannot be empty");
        }
        if !path.starts_with('/') {
            panic!("container mount path must be absolute (start with /)");
        }
        self.pipeline.tasks[self.index].mounts.push(Mount {
            resource: cache.id(),
            path: path.to_string(),
            mount_type: "cache".to_string(),
        });
        self
    }

    /// Sets the working directory inside the container.
    pub fn workdir(self, path: &str) -> Self {
        if path.is_empty() {
            panic!("container working directory cannot be empty");
        }
        if !path.starts_with('/') {
            panic!("container working directory must be absolute (start with /)");
        }
        self.pipeline.tasks[self.index].workdir = Some(path.to_string());
        self
    }

    /// Sets an environment variable.
    pub fn env(self, key: &str, value: &str) -> Self {
        if key.is_empty() {
            panic!("environment variable key cannot be empty");
        }
        self.pipeline.tasks[self.index]
            .env
            .insert(key.to_string(), value.to_string());
        self
    }

    /// Sets input file patterns for caching.
    pub fn inputs(self, patterns: &[&str]) -> Self {
        self.pipeline.tasks[self.index]
            .inputs
            .extend(patterns.iter().map(|s| s.to_string()));
        self
    }

    /// Sets a named output path.
    pub fn output(self, name: &str, path: &str) -> Self {
        if name.is_empty() {
            panic!("output name cannot be empty");
        }
        if path.is_empty() {
            panic!("output path cannot be empty");
        }
        self.pipeline.tasks[self.index]
            .outputs
            .insert(name.to_string(), path.to_string());
        self
    }

    /// Sets output paths (for backward compatibility).
    pub fn outputs(self, paths: &[&str]) -> Self {
        for (i, path) in paths.iter().enumerate() {
            if path.is_empty() {
                panic!("output path cannot be empty");
            }
            self.pipeline.tasks[self.index]
                .outputs
                .insert(format!("output_{}", i), path.to_string());
        }
        self
    }

    /// Sets dependencies - this task runs after the named tasks.
    pub fn after(self, tasks: &[&str]) -> Self {
        self.pipeline.tasks[self.index]
            .depends_on
            .extend(tasks.iter().map(|s| s.to_string()));
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
    pub fn when(self, condition: &str) -> Self {
        if condition.is_empty() {
            panic!("condition cannot be empty");
        }
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
    pub fn secret(self, name: &str) -> Self {
        if name.is_empty() {
            panic!("secret name cannot be empty");
        }
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
    pub fn secrets(self, names: &[&str]) -> Self {
        for name in names {
            if name.is_empty() {
                panic!("secret name cannot be empty");
            }
        }
        self.pipeline.tasks[self.index]
            .secrets
            .extend(names.iter().map(|s| s.to_string()));
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
    pub fn matrix(self, key: &str, values: &[&str]) -> Self {
        if key.is_empty() {
            panic!("matrix key cannot be empty");
        }
        if values.is_empty() {
            panic!("matrix values cannot be empty");
        }
        self.pipeline.tasks[self.index]
            .matrix
            .insert(key.to_string(), values.iter().map(|s| s.to_string()).collect());
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
    pub fn service(self, image: &str, name: &str) -> Self {
        if image.is_empty() {
            panic!("service image cannot be empty");
        }
        if name.is_empty() {
            panic!("service name cannot be empty");
        }
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
    pub fn timeout(self, seconds: u32) -> Self {
        if seconds == 0 {
            panic!("timeout must be greater than 0");
        }
        debug!(task = %self.pipeline.tasks[self.index].name, timeout = seconds, "setting timeout");
        self.pipeline.tasks[self.index].timeout = Some(seconds);
        self
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
}

impl Pipeline {
    /// Creates a new pipeline.
    pub fn new() -> Self {
        Pipeline {
            tasks: Vec::new(),
            dirs: Vec::new(),
            caches: Vec::new(),
        }
    }

    /// Creates a directory resource.
    pub fn dir(&mut self, path: &str) -> Directory {
        if path.is_empty() {
            panic!("directory path cannot be empty");
        }
        let dir = Directory {
            path: path.to_string(),
            globs: Vec::new(),
        };
        self.dirs.push(dir.clone());
        dir
    }

    /// Creates a named cache volume.
    pub fn cache(&mut self, name: &str) -> CacheVolume {
        if name.is_empty() {
            panic!("cache name cannot be empty");
        }
        let cache = CacheVolume {
            name: name.to_string(),
        };
        self.caches.push(cache.clone());
        cache
    }

    /// Creates a new task with the given name.
    pub fn task(&mut self, name: &str) -> Task<'_> {
        if name.is_empty() {
            panic!("task name cannot be empty");
        }
        if self.tasks.iter().any(|t| t.name == name) {
            panic!("task {:?} already exists", name);
        }
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

    /// Emits the pipeline as JSON to stdout if `--emit` flag is present.
    ///
    /// This method checks for `--emit` in command line arguments and if found,
    /// writes the pipeline JSON to stdout and exits the process with code 0.
    /// If emission fails, exits with code 1.
    ///
    /// **Note:** This method exits the process and does not return. For non-exiting
    /// behavior, use [`emit_to`] directly.
    pub fn emit(&self) {
        if env::args().any(|arg| arg == "--emit") {
            if let Err(e) = self.emit_to(&mut io::stdout()) {
                eprintln!("error: {}", e);
                std::process::exit(1);
            }
            std::process::exit(0);
        }
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
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        format!("task {:?} depends on unknown task {:?}", t.name, dep),
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
                Some(resources)
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
                    condition: t.condition.clone(),
                    secrets: if t.secrets.is_empty() {
                        None
                    } else {
                        Some(t.secrets.clone())
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
    outputs: Option<HashMap<String, String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    depends_on: Option<Vec<String>>,
    #[serde(rename = "when", skip_serializing_if = "Option::is_none")]
    condition: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    secrets: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    matrix: Option<HashMap<String, Vec<String>>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    services: Option<Vec<JsonService>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    retry: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    timeout: Option<u32>,
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

        assert_eq!(json["tasks"][0]["outputs"]["output_0"], "target/release/myapp");
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
        p.task("deploy")
            .run("./deploy.sh")
            .when("branch == 'main'");

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        assert_eq!(json["tasks"][0]["when"], "branch == 'main'");
    }

    #[test]
    fn test_when_tag_condition() {
        let mut p = Pipeline::new();
        p.task("release")
            .run("./release.sh")
            .when("tag != ''");

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
        p.task("deploy")
            .run("./deploy.sh")
            .secret("GITHUB_TOKEN");

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
        p.task("flaky")
            .run("./flaky.sh")
            .retry(2)
            .timeout(120);

        let mut buf = Vec::new();
        p.emit_to(&mut buf).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&buf).unwrap();

        assert_eq!(json["tasks"][0]["retry"], 2);
        assert_eq!(json["tasks"][0]["timeout"], 120);
    }
}
