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

// K8sTaskOptions provides Kubernetes-specific configuration for a task.
// These options are only used when running with the K8s target.
//
// Example:
//
//	s.Task("build").
//	    Run("go build").
//	    K8s(sykli.K8sTaskOptions{
//	        Resources: sykli.K8sResources{CPU: "2", Memory: "4Gi"},
//	        GPU:       1,
//	    })
type K8sTaskOptions struct {
	// --- Pod Scheduling ---

	// NodeSelector constrains the pod to nodes with matching labels.
	NodeSelector map[string]string

	// Tolerations allow the pod to schedule on tainted nodes.
	Tolerations []K8sToleration

	// Affinity rules for advanced scheduling.
	Affinity *K8sAffinity

	// PriorityClassName for pod priority.
	PriorityClassName string

	// --- Resources ---

	// Resources specifies CPU/memory requests and limits.
	Resources K8sResources

	// GPU requests NVIDIA GPUs.
	GPU int

	// --- Security ---

	// ServiceAccount to use for the pod.
	ServiceAccount string

	// SecurityContext for the container.
	SecurityContext *K8sSecurityContext

	// --- Networking ---

	// HostNetwork runs the pod in the host network namespace.
	HostNetwork bool

	// DNSPolicy overrides the default DNS policy.
	DNSPolicy string

	// --- Storage ---

	// Volumes defines additional volume mounts.
	Volumes []K8sVolume

	// --- Metadata ---

	// Labels to apply to the Job/Pod.
	Labels map[string]string

	// Annotations to apply to the Job/Pod.
	Annotations map[string]string

	// Namespace overrides the default namespace.
	Namespace string
}

// K8sResources specifies compute resources.
type K8sResources struct {
	RequestCPU    string
	RequestMemory string
	LimitCPU      string
	LimitMemory   string
	CPU           string // Shorthand: sets both request and limit
	Memory        string // Shorthand: sets both request and limit
}

// K8sToleration allows scheduling on tainted nodes.
type K8sToleration struct {
	Key      string
	Operator string // "Exists" or "Equal"
	Value    string
	Effect   string // "NoSchedule", "PreferNoSchedule", "NoExecute"
}

// K8sAffinity defines node/pod affinity rules.
type K8sAffinity struct {
	NodeAffinity    *K8sNodeAffinity
	PodAffinity     *K8sPodAffinity
	PodAntiAffinity *K8sPodAffinity
}

// K8sNodeAffinity for node selection rules.
type K8sNodeAffinity struct {
	RequiredLabels  map[string]string
	PreferredLabels map[string]string
}

// K8sPodAffinity for pod co-location rules.
type K8sPodAffinity struct {
	RequiredLabels map[string]string
	TopologyKey    string
}

// K8sSecurityContext defines security settings.
type K8sSecurityContext struct {
	RunAsUser            *int64
	RunAsGroup           *int64
	RunAsNonRoot         bool
	Privileged           bool
	ReadOnlyRootFilesystem bool
	AddCapabilities      []string
	DropCapabilities     []string
}

// K8sVolume defines additional volume mounts.
type K8sVolume struct {
	Name      string
	MountPath string
	ConfigMap *K8sConfigMapVolume
	Secret    *K8sSecretVolume
	EmptyDir  *K8sEmptyDirVolume
	HostPath  *K8sHostPathVolume
	PVC       *K8sPVCVolume
}

type K8sConfigMapVolume struct{ Name string }
type K8sSecretVolume struct{ Name string }
type K8sEmptyDirVolume struct{ Medium, SizeLimit string }
type K8sHostPathVolume struct{ Path, Type string }
type K8sPVCVolume struct{ ClaimName string }

// =============================================================================
// TASK K8S EXTENSION
// =============================================================================

// K8s adds Kubernetes-specific options to a task.
func (t *Task) K8s(opts K8sTaskOptions) *Task {
	t.k8sOptions = &opts
	return t
}

// MergeK8sOptions merges defaults with task-specific options.
// Task options override defaults. For maps, values are merged with task winning.
func MergeK8sOptions(defaults, task *K8sTaskOptions) *K8sTaskOptions {
	if defaults == nil {
		return task
	}
	if task == nil {
		// Return a copy of defaults
		copy := *defaults
		return &copy
	}

	result := *defaults // Start with defaults

	// Scalar overrides (task wins if non-zero)
	if task.Namespace != "" {
		result.Namespace = task.Namespace
	}
	if task.PriorityClassName != "" {
		result.PriorityClassName = task.PriorityClassName
	}
	if task.ServiceAccount != "" {
		result.ServiceAccount = task.ServiceAccount
	}
	if task.DNSPolicy != "" {
		result.DNSPolicy = task.DNSPolicy
	}
	if task.GPU > 0 {
		result.GPU = task.GPU
	}
	if task.HostNetwork {
		result.HostNetwork = task.HostNetwork
	}

	// Resources (task wins for each non-empty field)
	if task.Resources.CPU != "" {
		result.Resources.CPU = task.Resources.CPU
	}
	if task.Resources.Memory != "" {
		result.Resources.Memory = task.Resources.Memory
	}
	if task.Resources.RequestCPU != "" {
		result.Resources.RequestCPU = task.Resources.RequestCPU
	}
	if task.Resources.RequestMemory != "" {
		result.Resources.RequestMemory = task.Resources.RequestMemory
	}
	if task.Resources.LimitCPU != "" {
		result.Resources.LimitCPU = task.Resources.LimitCPU
	}
	if task.Resources.LimitMemory != "" {
		result.Resources.LimitMemory = task.Resources.LimitMemory
	}

	// Maps: merge with task values winning
	result.NodeSelector = mergeMaps(defaults.NodeSelector, task.NodeSelector)
	result.Labels = mergeMaps(defaults.Labels, task.Labels)
	result.Annotations = mergeMaps(defaults.Annotations, task.Annotations)

	// Slices: task replaces if non-empty
	if len(task.Tolerations) > 0 {
		result.Tolerations = task.Tolerations
	}
	if len(task.Volumes) > 0 {
		result.Volumes = task.Volumes
	}

	// Structs: task replaces if non-nil
	if task.Affinity != nil {
		result.Affinity = task.Affinity
	}
	if task.SecurityContext != nil {
		result.SecurityContext = task.SecurityContext
	}

	return &result
}

// mergeMaps merges two string maps, with b's values overriding a's.
func mergeMaps(a, b map[string]string) map[string]string {
	if len(a) == 0 && len(b) == 0 {
		return nil
	}
	result := make(map[string]string)
	for k, v := range a {
		result[k] = v
	}
	for k, v := range b {
		result[k] = v
	}
	return result
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
func ValidateK8sOptions(opts *K8sTaskOptions) []error {
	if opts == nil {
		return nil
	}

	var errs []error

	// Validate resources
	errs = append(errs, validateK8sResources(&opts.Resources)...)

	// Validate tolerations
	for i, t := range opts.Tolerations {
		if t.Operator != "" && t.Operator != "Exists" && t.Operator != "Equal" {
			errs = append(errs, K8sValidationError{
				Field:   fmt.Sprintf("tolerations[%d].operator", i),
				Value:   t.Operator,
				Message: "must be 'Exists' or 'Equal'",
			})
		}
		if t.Effect != "" && t.Effect != "NoSchedule" && t.Effect != "PreferNoSchedule" && t.Effect != "NoExecute" {
			errs = append(errs, K8sValidationError{
				Field:   fmt.Sprintf("tolerations[%d].effect", i),
				Value:   t.Effect,
				Message: "must be 'NoSchedule', 'PreferNoSchedule', or 'NoExecute'",
			})
		}
	}

	// Validate DNS policy
	validDNSPolicies := []string{"", "ClusterFirst", "ClusterFirstWithHostNet", "Default", "None"}
	if opts.DNSPolicy != "" && !contains(validDNSPolicies, opts.DNSPolicy) {
		errs = append(errs, K8sValidationError{
			Field:   "dnsPolicy",
			Value:   opts.DNSPolicy,
			Message: "must be one of: ClusterFirst, ClusterFirstWithHostNet, Default, None",
		})
	}

	// Validate volumes
	for i, v := range opts.Volumes {
		if v.Name == "" {
			errs = append(errs, K8sValidationError{
				Field:   fmt.Sprintf("volumes[%d].name", i),
				Value:   "",
				Message: "volume name is required",
			})
		}
		if v.MountPath == "" {
			errs = append(errs, K8sValidationError{
				Field:   fmt.Sprintf("volumes[%d].mountPath", i),
				Value:   "",
				Message: "mount path is required",
			})
		} else if !strings.HasPrefix(v.MountPath, "/") {
			errs = append(errs, K8sValidationError{
				Field:   fmt.Sprintf("volumes[%d].mountPath", i),
				Value:   v.MountPath,
				Message: "mount path must be absolute (start with /)",
			})
		}
	}

	return errs
}

func validateK8sResources(r *K8sResources) []error {
	var errs []error

	// Validate memory fields
	memoryFields := []struct {
		name  string
		value string
	}{
		{"resources.memory", r.Memory},
		{"resources.requestMemory", r.RequestMemory},
		{"resources.limitMemory", r.LimitMemory},
	}
	for _, f := range memoryFields {
		if err := validateK8sMemory(f.name, f.value); err != nil {
			errs = append(errs, err)
		}
	}

	// Validate CPU fields
	cpuFields := []struct {
		name  string
		value string
	}{
		{"resources.cpu", r.CPU},
		{"resources.requestCPU", r.RequestCPU},
		{"resources.limitCPU", r.LimitCPU},
	}
	for _, f := range cpuFields {
		if err := validateK8sCPU(f.name, f.value); err != nil {
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
		// Provide helpful suggestions for common mistakes
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

func contains(slice []string, item string) bool {
	for _, s := range slice {
		if s == item {
			return true
		}
	}
	return false
}
