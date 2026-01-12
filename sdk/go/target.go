package sykli

import (
	"context"
	"fmt"
	"regexp"
	"strings"
)

// =============================================================================
// TARGET INTERFACE - The Core
// =============================================================================

// Target is the core interface - just one method.
//
// A Target is something that can run tasks. That's it.
//
// Simple targets (GitHub Actions, SSH, Lambda) implement only this.
// Complex targets opt into additional capabilities.
//
// Example - Simple target:
//
//	type GitHubActionsTarget struct{}
//
//	func (g *GitHubActionsTarget) RunTask(ctx context.Context, task TaskSpec) Result {
//	    // Trigger workflow, wait for completion
//	    return Result{Success: true}
//	}
//
// Example - With capabilities:
//
//	type MyTarget struct {
//	    EnvSecrets   // Embed for environment-based secrets
//	    LocalStorage // Embed for filesystem storage
//	}
//
//	func (m *MyTarget) RunTask(ctx context.Context, task TaskSpec) Result {
//	    // Use embedded capabilities + custom logic
//	}
type Target interface {
	// RunTask executes a single task.
	//
	// This is the ONLY required method. Everything else is optional.
	RunTask(ctx context.Context, task TaskSpec) Result
}

// =============================================================================
// OPTIONAL CAPABILITIES - Implement what you need
// =============================================================================

// Lifecycle adds setup/teardown around pipeline execution.
//
// Implement this if your target needs to:
//   - Initialize connections before running
//   - Clean up after the pipeline completes
//   - Maintain state across tasks
//
// Example:
//
//	type MyTarget struct {
//	    conn *Connection
//	}
//
//	func (m *MyTarget) Setup(ctx context.Context) error {
//	    m.conn = connect()
//	    return nil
//	}
//
//	func (m *MyTarget) Teardown(ctx context.Context) error {
//	    return m.conn.Close()
//	}
type Lifecycle interface {
	Setup(ctx context.Context) error
	Teardown(ctx context.Context) error
}

// Secrets provides secret resolution.
//
// Implement this if your target can provide secret values
// (API keys, tokens, passwords) to tasks.
//
// Example:
//
//	func (m *MyTarget) ResolveSecret(ctx context.Context, name string) (string, error) {
//	    return vault.Read("secret/" + name)
//	}
type Secrets interface {
	ResolveSecret(ctx context.Context, name string) (string, error)
}

// Storage provides volume and artifact management.
//
// Implement this if your target needs to:
//   - Create storage volumes for tasks
//   - Pass artifacts between tasks
//   - Persist build outputs
type Storage interface {
	CreateVolume(ctx context.Context, name string, opts VolumeOptions) (Volume, error)
	ArtifactPath(taskName, artifactName string) string
	CopyArtifact(ctx context.Context, src, dst string) error
}

// Services provides service container management.
//
// Implement this if your target can run background services
// (databases, caches) that tasks can connect to.
type Services interface {
	StartServices(ctx context.Context, taskName string, services []ServiceSpec) (interface{}, error)
	StopServices(ctx context.Context, networkInfo interface{}) error
}

// =============================================================================
// CAPABILITY CHECKING
// =============================================================================

// HasLifecycle checks if a target implements Lifecycle.
func HasLifecycle(t Target) bool {
	_, ok := t.(Lifecycle)
	return ok
}

// HasSecrets checks if a target implements Secrets.
func HasSecrets(t Target) bool {
	_, ok := t.(Secrets)
	return ok
}

// HasStorage checks if a target implements Storage.
func HasStorage(t Target) bool {
	_, ok := t.(Storage)
	return ok
}

// HasServices checks if a target implements Services.
func HasServices(t Target) bool {
	_, ok := t.(Services)
	return ok
}

// AsLifecycle returns the Lifecycle interface if implemented.
func AsLifecycle(t Target) (Lifecycle, bool) {
	l, ok := t.(Lifecycle)
	return l, ok
}

// AsSecrets returns the Secrets interface if implemented.
func AsSecrets(t Target) (Secrets, bool) {
	s, ok := t.(Secrets)
	return s, ok
}

// AsStorage returns the Storage interface if implemented.
func AsStorage(t Target) (Storage, bool) {
	s, ok := t.(Storage)
	return s, ok
}

// AsServices returns the Services interface if implemented.
func AsServices(t Target) (Services, bool) {
	s, ok := t.(Services)
	return s, ok
}

// =============================================================================
// BUILT-IN CAPABILITY IMPLEMENTATIONS
// =============================================================================

// EnvSecrets resolves secrets from environment variables.
// Embed this in your target to get env-based secrets for free.
//
// Example:
//
//	type MyTarget struct {
//	    EnvSecrets
//	}
type EnvSecrets struct{}

// ResolveSecret reads from environment variables.
func (EnvSecrets) ResolveSecret(ctx context.Context, name string) (string, error) {
	// Implementation in executor - this is just the interface
	return "", nil
}

// =============================================================================
// TYPES
// =============================================================================

// TaskSpec contains all information needed to execute a task.
type TaskSpec struct {
	Name      string
	Command   string
	Image     string            // Container image (empty = shell)
	Workdir   string            // Working directory inside container
	Env       map[string]string // Environment variables
	Mounts    []MountSpec       // Volume mounts
	Timeout   int               // Timeout in seconds (0 = default)
	DependsOn []string          // For informational purposes
	Services  []ServiceSpec     // Service containers for this task

	// Target-specific options (nil if not using that target)
	K8s *K8sTaskOptions
}

// MountSpec describes a volume mount.
type MountSpec struct {
	Volume Volume // The volume to mount
	Path   string // Mount path inside container
}

// ServiceSpec describes a service container.
type ServiceSpec struct {
	Name  string // Service name (used as hostname)
	Image string // Container image
}

// Result contains execution results.
type Result struct {
	Success  bool
	ExitCode int
	Output   string // Captured stdout/stderr
	Duration int64  // Execution time in milliseconds
	Error    error  // Non-nil if execution failed
}

// VolumeOptions for creating volumes.
type VolumeOptions struct {
	Size string // e.g., "1Gi", "10Gi"
}

// Volume represents provisioned storage.
type Volume interface {
	ID() string
	HostPath() string   // Empty for non-local targets
	Reference() string  // Target-specific reference
}

// =============================================================================
// K8S TARGET OPTIONS
// =============================================================================

// K8sOptions provides Kubernetes-specific configuration for a task.
// This is a minimal API covering 95% of CI use cases.
//
// For advanced options (tolerations, affinity, security contexts),
// use K8sRaw() to pass raw JSON.
//
// Example:
//
//	s.Task("build").
//	    Run("go build").
//	    K8s(sykli.K8sOptions{Memory: "4Gi", CPU: "2"})
//
//	s.Task("train").
//	    Run("python train.py").
//	    K8s(sykli.K8sOptions{Memory: "32Gi", GPU: 1})
type K8sOptions struct {
	// Memory sets both request and limit (e.g., "4Gi", "512Mi").
	Memory string

	// CPU sets both request and limit (e.g., "2", "500m").
	CPU string

	// GPU requests NVIDIA GPUs (e.g., 1, 2).
	GPU int
}

// K8sTaskOptions is an alias for backward compatibility.
// Deprecated: Use K8sOptions instead.
type K8sTaskOptions = K8sOptions

// =============================================================================
// TASK K8S EXTENSION
// =============================================================================

// K8s adds Kubernetes-specific options to a task.
//
// Example:
//
//	s.Task("build").Run("go build").K8s(sykli.K8sOptions{Memory: "4Gi", CPU: "2"})
func (t *Task) K8s(opts K8sOptions) *Task {
	t.k8sOptions = &opts
	return t
}

// K8sRaw adds raw Kubernetes configuration as JSON.
// Use this for advanced options not covered by K8sOptions (tolerations, affinity, etc.).
//
// The JSON is passed directly to the executor and merged with K8sOptions.
// K8sOptions fields take precedence over K8sRaw for overlapping settings.
//
// Example:
//
//	// GPU node with toleration
//	s.Task("train").
//	    K8s(sykli.K8sOptions{Memory: "32Gi", GPU: 1}).
//	    K8sRaw(`{"nodeSelector": {"gpu": "true"}, "tolerations": [{"key": "gpu", "effect": "NoSchedule"}]}`)
func (t *Task) K8sRaw(jsonConfig string) *Task {
	t.k8sRaw = jsonConfig
	return t
}

// MergeK8sOptions merges defaults with task-specific options.
// Task options override defaults.
func MergeK8sOptions(defaults, task *K8sOptions) *K8sOptions {
	if defaults == nil {
		return task
	}
	if task == nil {
		copy := *defaults
		return &copy
	}

	result := *defaults

	if task.Memory != "" {
		result.Memory = task.Memory
	}
	if task.CPU != "" {
		result.CPU = task.CPU
	}
	if task.GPU > 0 {
		result.GPU = task.GPU
	}

	return &result
}

// =============================================================================
// K8S VALIDATION
// =============================================================================

// K8s quantity patterns - shared validation logic
var (
	// Memory: Ki, Mi, Gi, Ti, Pi, Ei (binary) or k, M, G, T, P, E (decimal)
	k8sMemoryPattern = regexp.MustCompile(`^[0-9]+(\.[0-9]+)?(Ki|Mi|Gi|Ti|Pi|Ei|k|M|G|T|P|E)?$`)
	// CPU: whole numbers, decimals, or millicores (e.g., "100m", "0.5", "2")
	k8sCPUPattern = regexp.MustCompile(`^[0-9]+(\.[0-9]+)?m?$`)
)

// K8sValidationError contains details about K8s option validation failures.
type K8sValidationError struct {
	Field   string
	Value   string
	Message string
}

func (e K8sValidationError) Error() string {
	return fmt.Sprintf("k8s.%s: %s (got %q)", e.Field, e.Message, e.Value)
}

// ValidateK8sOptions validates K8s options and returns all errors found.
// Returns nil if validation passes.
func ValidateK8sOptions(opts *K8sOptions) []error {
	if opts == nil {
		return nil
	}

	var errs []error

	// Validate memory
	if opts.Memory != "" {
		if err := validateK8sMemory("memory", opts.Memory); err != nil {
			errs = append(errs, err)
		}
	}

	// Validate CPU
	if opts.CPU != "" {
		if err := validateK8sCPU("cpu", opts.CPU); err != nil {
			errs = append(errs, err)
		}
	}

	return errs
}

func validateK8sMemory(field, value string) error {
	if value == "" {
		return nil
	}
	if !k8sMemoryPattern.MatchString(value) {
		suggestion := ""
		lower := strings.ToLower(value)
		if strings.HasSuffix(lower, "gb") {
			suggestion = " (did you mean 'Gi'?)"
		} else if strings.HasSuffix(lower, "mb") {
			suggestion = " (did you mean 'Mi'?)"
		} else if strings.HasSuffix(lower, "kb") {
			suggestion = " (did you mean 'Ki'?)"
		}
		return K8sValidationError{
			Field:   field,
			Value:   value,
			Message: "invalid memory format, use Ki/Mi/Gi/Ti (e.g., '512Mi', '4Gi')" + suggestion,
		}
	}
	return nil
}

func validateK8sCPU(field, value string) error {
	if value == "" {
		return nil
	}
	if !k8sCPUPattern.MatchString(value) {
		return K8sValidationError{
			Field:   field,
			Value:   value,
			Message: "invalid CPU format, use cores or millicores (e.g., '500m', '0.5', '2')",
		}
	}
	return nil
}
