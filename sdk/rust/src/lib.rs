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
        if path.is_empty() || !path.starts_with('/') {
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
        if path.is_empty() || !path.starts_with('/') {
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

    /// Emits the pipeline as JSON if --emit flag is present.
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
}

#[derive(Serialize)]
struct JsonMount {
    resource: String,
    path: String,
    #[serde(rename = "type")]
    type_: String,
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
}
