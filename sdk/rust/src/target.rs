//! Target interface - where pipelines execute.
//!
//! A Target is simply something that can run tasks. That's it.
//!
//! # The Minimal Interface
//!
//! ```rust,ignore
//! use sykli::target::{Target, TaskSpec, Result};
//!
//! struct MyTarget;
//!
//! impl Target for MyTarget {
//!     fn run_task(&self, task: &TaskSpec) -> Result {
//!         // Execute the task somehow
//!         Result::success()
//!     }
//! }
//! ```
//!
//! That's all you need. One method.
//!
//! # Optional Capabilities
//!
//! Targets can opt into additional capabilities by implementing
//! optional traits. These are building blocks - use what you need:
//!
//! - [`Lifecycle`] - setup/teardown around pipeline execution
//! - [`Secrets`] - resolve secrets by name
//! - [`Storage`] - manage volumes and artifacts
//! - [`Services`] - start/stop service containers
//!
//! # Examples
//!
//! ## Simple Target (GitHub Actions)
//!
//! ```rust,ignore
//! struct GitHubActionsTarget {
//!     workflow: String,
//! }
//!
//! impl Target for GitHubActionsTarget {
//!     fn run_task(&self, task: &TaskSpec) -> Result {
//!         // Trigger workflow via GitHub API
//!         // Wait for completion
//!         // Return result
//!         Result::success()
//!     }
//! }
//! ```
//!
//! ## Full-Featured Target
//!
//! ```rust,ignore
//! struct MyK8sTarget {
//!     namespace: String,
//!     kubeconfig: Option<String>,
//! }
//!
//! impl Target for MyK8sTarget {
//!     fn run_task(&self, task: &TaskSpec) -> Result { ... }
//! }
//!
//! impl Lifecycle for MyK8sTarget {
//!     fn setup(&mut self) -> std::result::Result<(), Error> { ... }
//!     fn teardown(&mut self) -> std::result::Result<(), Error> { ... }
//! }
//!
//! impl Secrets for MyK8sTarget {
//!     fn resolve_secret(&self, name: &str) -> std::result::Result<String, Error> { ... }
//! }
//! ```

use std::collections::HashMap;
use std::error::Error as StdError;
use std::fmt;
use std::time::Duration;

// =============================================================================
// ERROR TYPE
// =============================================================================

/// Error type for target operations.
#[derive(Debug)]
pub struct Error {
    message: String,
    source: Option<Box<dyn StdError + Send + Sync>>,
}

impl Error {
    /// Creates a new error with the given message.
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            source: None,
        }
    }

    /// Creates an error with a source cause.
    pub fn with_source(message: impl Into<String>, source: impl StdError + Send + Sync + 'static) -> Self {
        Self {
            message: message.into(),
            source: Some(Box::new(source)),
        }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.message)
    }
}

impl StdError for Error {
    fn source(&self) -> Option<&(dyn StdError + 'static)> {
        self.source.as_ref().map(|e| e.as_ref() as _)
    }
}

// =============================================================================
// TASK SPEC
// =============================================================================

/// Task specification passed to [`Target::run_task`].
#[derive(Debug, Clone)]
pub struct TaskSpec {
    /// Task name.
    pub name: String,
    /// Command to execute.
    pub command: String,
    /// Container image (empty = shell execution).
    pub image: Option<String>,
    /// Working directory inside container.
    pub workdir: Option<String>,
    /// Environment variables.
    pub env: HashMap<String, String>,
    /// Volume mounts.
    pub mounts: Vec<MountSpec>,
    /// Timeout in seconds.
    pub timeout: Option<u32>,
    /// Service containers for this task.
    pub services: Vec<ServiceSpec>,
}

impl TaskSpec {
    /// Creates a new task spec with the given name and command.
    pub fn new(name: impl Into<String>, command: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            command: command.into(),
            image: None,
            workdir: None,
            env: HashMap::new(),
            mounts: Vec::new(),
            timeout: None,
            services: Vec::new(),
        }
    }
}

/// Volume mount specification.
#[derive(Debug, Clone)]
pub struct MountSpec {
    /// Host path or volume reference.
    pub source: String,
    /// Mount path inside container.
    pub target: String,
    /// Mount type (directory, cache).
    pub mount_type: MountType,
}

/// Type of mount.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MountType {
    /// Directory mount (bind mount).
    Directory,
    /// Named cache volume.
    Cache,
}

/// Service container specification.
#[derive(Debug, Clone)]
pub struct ServiceSpec {
    /// Service name (used as hostname).
    pub name: String,
    /// Container image.
    pub image: String,
}

// =============================================================================
// RESULT
// =============================================================================

/// Result from task execution.
#[derive(Debug, Clone)]
pub struct Result {
    /// Whether the task succeeded.
    pub success: bool,
    /// Exit code.
    pub exit_code: i32,
    /// Captured output (stdout/stderr).
    pub output: String,
    /// Execution duration.
    pub duration: Duration,
    /// Error message if failed.
    pub error: Option<String>,
}

impl Result {
    /// Creates a successful result.
    pub fn success() -> Self {
        Self {
            success: true,
            exit_code: 0,
            output: String::new(),
            duration: Duration::ZERO,
            error: None,
        }
    }

    /// Creates a successful result with output.
    pub fn success_with_output(output: impl Into<String>, duration: Duration) -> Self {
        Self {
            success: true,
            exit_code: 0,
            output: output.into(),
            duration,
            error: None,
        }
    }

    /// Creates a failed result.
    pub fn failure(exit_code: i32, output: impl Into<String>) -> Self {
        Self {
            success: false,
            exit_code,
            output: output.into(),
            duration: Duration::ZERO,
            error: None,
        }
    }

    /// Creates a failed result with an error message.
    pub fn error(message: impl Into<String>) -> Self {
        Self {
            success: false,
            exit_code: 1,
            output: String::new(),
            duration: Duration::ZERO,
            error: Some(message.into()),
        }
    }
}

// =============================================================================
// THE CORE TRAIT - Just one method
// =============================================================================

/// The core Target trait - just one method.
///
/// A Target is something that can run tasks. That's it.
///
/// # Example
///
/// ```rust,ignore
/// use sykli::target::{Target, TaskSpec, Result};
///
/// struct ShellTarget;
///
/// impl Target for ShellTarget {
///     fn run_task(&self, task: &TaskSpec) -> Result {
///         // Execute via shell
///         let output = std::process::Command::new("sh")
///             .arg("-c")
///             .arg(&task.command)
///             .output()
///             .expect("failed to execute");
///
///         if output.status.success() {
///             Result::success_with_output(
///                 String::from_utf8_lossy(&output.stdout),
///                 std::time::Duration::ZERO,
///             )
///         } else {
///             Result::failure(
///                 output.status.code().unwrap_or(1),
///                 String::from_utf8_lossy(&output.stderr),
///             )
///         }
///     }
/// }
/// ```
pub trait Target {
    /// Execute a task.
    ///
    /// This is the ONLY required method. Everything else is optional.
    fn run_task(&self, task: &TaskSpec) -> Result;
}

// =============================================================================
// OPTIONAL CAPABILITIES
// =============================================================================

/// Optional capability: Setup and teardown around pipeline execution.
///
/// Implement this if your target needs to:
/// - Initialize connections before running
/// - Clean up after the pipeline completes
/// - Maintain state across tasks
///
/// # Example
///
/// ```rust,ignore
/// struct DatabaseTarget {
///     connection: Option<Connection>,
/// }
///
/// impl Lifecycle for DatabaseTarget {
///     fn setup(&mut self) -> std::result::Result<(), Error> {
///         self.connection = Some(Connection::new()?);
///         Ok(())
///     }
///
///     fn teardown(&mut self) -> std::result::Result<(), Error> {
///         if let Some(conn) = self.connection.take() {
///             conn.close()?;
///         }
///         Ok(())
///     }
/// }
/// ```
pub trait Lifecycle {
    /// Initialize the target before pipeline execution.
    fn setup(&mut self) -> std::result::Result<(), Error>;

    /// Clean up after pipeline execution.
    fn teardown(&mut self) -> std::result::Result<(), Error>;
}

/// Optional capability: Resolve secrets by name.
///
/// Implement this if your target can provide secret values
/// (API keys, tokens, passwords) to tasks.
///
/// # Example
///
/// ```rust,ignore
/// impl Secrets for VaultTarget {
///     fn resolve_secret(&self, name: &str) -> std::result::Result<String, Error> {
///         self.vault_client.read(&format!("secret/{}", name))
///             .map_err(|e| Error::with_source("vault read failed", e))
///     }
/// }
/// ```
pub trait Secrets {
    /// Resolve a secret value by name.
    fn resolve_secret(&self, name: &str) -> std::result::Result<String, Error>;
}

/// Volume reference returned by [`Storage::create_volume`].
#[derive(Debug, Clone)]
pub struct Volume {
    /// Unique volume ID.
    pub id: String,
    /// Host path (if applicable).
    pub host_path: Option<String>,
    /// Target-specific reference.
    pub reference: String,
}

/// Options for volume creation.
#[derive(Debug, Clone, Default)]
pub struct VolumeOptions {
    /// Volume size (e.g., "1Gi").
    pub size: Option<String>,
}

/// Optional capability: Manage volumes and artifacts.
///
/// Implement this if your target needs to:
/// - Create storage volumes for tasks
/// - Pass artifacts between tasks
/// - Persist build outputs
pub trait Storage {
    /// Create a storage volume.
    fn create_volume(&self, name: &str, opts: &VolumeOptions) -> std::result::Result<Volume, Error>;

    /// Get the path where an artifact should be stored.
    fn artifact_path(&self, task_name: &str, artifact_name: &str) -> String;

    /// Copy an artifact from source to destination.
    fn copy_artifact(&self, src: &str, dst: &str) -> std::result::Result<(), Error>;
}

/// Network info returned by [`Services::start_services`].
#[derive(Debug, Clone)]
pub struct NetworkInfo {
    /// Network name or ID.
    pub network: String,
    /// Container IDs.
    pub containers: Vec<String>,
}

/// Optional capability: Run service containers.
///
/// Implement this if your target can run background services
/// (databases, caches) that tasks can connect to.
pub trait Services {
    /// Start service containers for a task.
    fn start_services(&self, task_name: &str, services: &[ServiceSpec]) -> std::result::Result<NetworkInfo, Error>;

    /// Stop and clean up service containers.
    fn stop_services(&self, network_info: &NetworkInfo) -> std::result::Result<(), Error>;
}

// =============================================================================
// CAPABILITY CHECKING
// =============================================================================

/// Check if a target implements [`Lifecycle`].
pub fn has_lifecycle<T: Target + ?Sized>(_target: &T) -> bool {
    // In Rust, we can't do runtime trait checking like Go/Elixir
    // Users should use the Any trait or explicit type checks
    false
}

// =============================================================================
// BUILT-IN IMPLEMENTATIONS
// =============================================================================

/// Resolves secrets from environment variables.
///
/// # Example
///
/// ```rust,ignore
/// struct MyTarget {
///     secrets: EnvSecrets,
/// }
///
/// // Delegate to EnvSecrets
/// impl Secrets for MyTarget {
///     fn resolve_secret(&self, name: &str) -> std::result::Result<String, Error> {
///         self.secrets.resolve_secret(name)
///     }
/// }
/// ```
#[derive(Debug, Clone, Default)]
pub struct EnvSecrets;

impl Secrets for EnvSecrets {
    fn resolve_secret(&self, name: &str) -> std::result::Result<String, Error> {
        std::env::var(name).map_err(|_| Error::new(format!("secret not found: {}", name)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct TestTarget;

    impl Target for TestTarget {
        fn run_task(&self, _task: &TaskSpec) -> Result {
            Result::success()
        }
    }

    #[test]
    fn test_target_trait() {
        let target = TestTarget;
        let task = TaskSpec::new("test", "echo hello");
        let result = target.run_task(&task);
        assert!(result.success);
    }

    #[test]
    fn test_env_secrets() {
        std::env::set_var("TEST_SECRET", "secret_value");
        let secrets = EnvSecrets;
        let value = secrets.resolve_secret("TEST_SECRET").unwrap();
        assert_eq!(value, "secret_value");
        std::env::remove_var("TEST_SECRET");
    }

    #[test]
    fn test_env_secrets_not_found() {
        let secrets = EnvSecrets;
        let result = secrets.resolve_secret("NONEXISTENT_SECRET");
        assert!(result.is_err());
    }

    #[test]
    fn test_result_success() {
        let result = Result::success();
        assert!(result.success);
        assert_eq!(result.exit_code, 0);
    }

    #[test]
    fn test_result_failure() {
        let result = Result::failure(1, "error output");
        assert!(!result.success);
        assert_eq!(result.exit_code, 1);
        assert_eq!(result.output, "error output");
    }
}
