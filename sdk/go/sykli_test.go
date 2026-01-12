package sykli

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

// Helper to capture emitted JSON
func emitJSON(p *Pipeline) (map[string]interface{}, error) {
	var buf bytes.Buffer
	if err := p.EmitTo(&buf); err != nil {
		return nil, err
	}
	var result map[string]interface{}
	if err := json.Unmarshal(buf.Bytes(), &result); err != nil {
		return nil, err
	}
	return result, nil
}

// Helper struct for task assertions
type taskJSON struct {
	Name      string            `json:"name"`
	Command   string            `json:"command"`
	Inputs    []string          `json:"inputs"`
	Outputs   map[string]string `json:"outputs"`
	DependsOn []string          `json:"depends_on"`
}

func getTask(result map[string]interface{}, name string) *taskJSON {
	tasks := result["tasks"].([]interface{})
	for _, t := range tasks {
		task := t.(map[string]interface{})
		if task["name"] == name {
			tj := &taskJSON{
				Name:    task["name"].(string),
				Command: task["command"].(string),
			}
			if inputs, ok := task["inputs"].([]interface{}); ok {
				for _, i := range inputs {
					tj.Inputs = append(tj.Inputs, i.(string))
				}
			}
			if outputs, ok := task["outputs"].(map[string]interface{}); ok {
				tj.Outputs = make(map[string]string)
				for k, v := range outputs {
					tj.Outputs[k] = v.(string)
				}
			}
			if deps, ok := task["depends_on"].([]interface{}); ok {
				for _, d := range deps {
					tj.DependsOn = append(tj.DependsOn, d.(string))
				}
			}
			return tj
		}
	}
	return nil
}

func TestBasicTask(t *testing.T) {
	p := New()
	p.Task("test").Run("go test ./...")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	task := getTask(result, "test")
	if task == nil {
		t.Fatal("task 'test' not found")
	}
	if task.Command != "go test ./..." {
		t.Errorf("expected command 'go test ./...', got %q", task.Command)
	}
}

func TestTaskWithInputs(t *testing.T) {
	p := New()
	p.Task("test").Run("go test").Inputs("**/*.go", "go.mod")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	task := getTask(result, "test")
	if len(task.Inputs) != 2 {
		t.Errorf("expected 2 inputs, got %d", len(task.Inputs))
	}
}

func TestTaskWithOutputs(t *testing.T) {
	p := New()
	p.Task("build").Run("go build -o app").Outputs("app")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	task := getTask(result, "build")
	if len(task.Outputs) != 1 {
		t.Errorf("expected 1 output, got %d", len(task.Outputs))
	}
}

func TestTaskDependencies(t *testing.T) {
	p := New()
	p.Task("test").Run("go test")
	p.Task("build").Run("go build").After("test")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	task := getTask(result, "build")
	if len(task.DependsOn) != 1 || task.DependsOn[0] != "test" {
		t.Errorf("expected depends_on=['test'], got %v", task.DependsOn)
	}
}

func TestMultipleDependencies(t *testing.T) {
	p := New()
	p.Task("lint").Run("go vet")
	p.Task("test").Run("go test")
	p.Task("build").Run("go build").After("lint", "test")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	task := getTask(result, "build")
	if len(task.DependsOn) != 2 {
		t.Errorf("expected 2 dependencies, got %d", len(task.DependsOn))
	}
}

func TestFluentChaining(t *testing.T) {
	p := New()
	p.Task("build").
		Run("go build -o app").
		Inputs("**/*.go").
		Outputs("app").
		After("test")

	// Just verify it compiles and doesn't panic
	p.Task("test").Run("go test")

	_, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}
}

func TestGoPresetTest(t *testing.T) {
	p := New()
	p.Go().Test()

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	task := getTask(result, "test")
	if task.Command != "go test ./..." {
		t.Errorf("expected 'go test ./...', got %q", task.Command)
	}
	if len(task.Inputs) != 3 {
		t.Errorf("expected 3 inputs (Go files), got %d", len(task.Inputs))
	}
}

func TestGoPresetLint(t *testing.T) {
	p := New()
	p.Go().Lint()

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	task := getTask(result, "lint")
	if task.Command != "go vet ./..." {
		t.Errorf("expected 'go vet ./...', got %q", task.Command)
	}
}

func TestGoPresetBuild(t *testing.T) {
	p := New()
	p.Go().Build("./myapp")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	task := getTask(result, "build")
	if task.Command != "go build -o ./myapp" {
		t.Errorf("expected 'go build -o ./myapp', got %q", task.Command)
	}
}

func TestGoPresetWithDeps(t *testing.T) {
	p := New()
	p.Go().Test()
	p.Go().Lint()
	p.Go().Build("./app").After("test", "lint")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	task := getTask(result, "build")
	if len(task.DependsOn) != 2 {
		t.Errorf("expected 2 deps, got %d", len(task.DependsOn))
	}
}

func TestDuplicateTaskNamePanics(t *testing.T) {
	defer func() {
		if r := recover(); r == nil {
			t.Error("expected panic for duplicate task name")
		}
	}()

	p := New()
	p.Task("test").Run("go test")
	p.Task("test").Run("go test again") // Should panic
}

func TestEmptyTaskNamePanics(t *testing.T) {
	defer func() {
		if r := recover(); r == nil {
			t.Error("expected panic for empty task name")
		}
	}()

	p := New()
	p.Task("").Run("some command") // Should panic
}

func TestTaskWithNoCommandFails(t *testing.T) {
	p := New()
	p.Task("incomplete") // No Run() called

	_, err := emitJSON(p)
	if err == nil {
		t.Error("expected error for task without command")
	}
}

func TestUnknownDependencyFails(t *testing.T) {
	p := New()
	p.Task("build").Run("go build").After("nonexistent")

	_, err := emitJSON(p)
	if err == nil {
		t.Error("expected error for unknown dependency")
	}
}

func TestJSONStructure(t *testing.T) {
	p := New()
	p.Task("test").Run("go test ./...").Inputs("**/*.go")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	// Check version
	if result["version"] != "1" {
		t.Errorf("expected version '1', got %v", result["version"])
	}

	// Check tasks array exists
	tasks, ok := result["tasks"].([]interface{})
	if !ok {
		t.Fatal("tasks should be an array")
	}
	if len(tasks) != 1 {
		t.Errorf("expected 1 task, got %d", len(tasks))
	}
}

// ----- WHEN CONDITION TESTS -----

func TestWhenBranchCondition(t *testing.T) {
	p := New()
	p.Task("deploy").Run("./deploy.sh").When("branch == 'main'")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	task := getTask(result, "deploy")
	taskMap := result["tasks"].([]interface{})[0].(map[string]interface{})
	if taskMap["when"] != "branch == 'main'" {
		t.Errorf("expected when='branch == 'main'', got %v", taskMap["when"])
	}
	_ = task // silence unused warning
}

func TestWhenTagCondition(t *testing.T) {
	p := New()
	p.Task("release").Run("./release.sh").When("tag != ''")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	taskMap := result["tasks"].([]interface{})[0].(map[string]interface{})
	if taskMap["when"] != "tag != ''" {
		t.Errorf("expected when=\"tag != ''\", got %v", taskMap["when"])
	}
}

func TestWhenNotSet(t *testing.T) {
	p := New()
	p.Task("test").Run("go test")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	taskMap := result["tasks"].([]interface{})[0].(map[string]interface{})
	if _, ok := taskMap["when"]; ok {
		t.Error("expected when to be omitted when not set")
	}
}

func TestWhenEmptyPanics(t *testing.T) {
	defer func() {
		if r := recover(); r == nil {
			t.Error("expected panic for empty condition")
		}
	}()

	p := New()
	p.Task("test").Run("go test").When("")
}

// ----- SECRET TESTS -----

func TestSecretSingle(t *testing.T) {
	p := New()
	p.Task("deploy").Run("./deploy.sh").Secret("GITHUB_TOKEN")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	taskMap := result["tasks"].([]interface{})[0].(map[string]interface{})
	secrets := taskMap["secrets"].([]interface{})
	if len(secrets) != 1 {
		t.Errorf("expected 1 secret, got %d", len(secrets))
	}
	if secrets[0] != "GITHUB_TOKEN" {
		t.Errorf("expected GITHUB_TOKEN, got %v", secrets[0])
	}
}

func TestSecretMultiple(t *testing.T) {
	p := New()
	p.Task("deploy").Run("./deploy.sh").Secret("GITHUB_TOKEN").Secret("NPM_TOKEN")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	taskMap := result["tasks"].([]interface{})[0].(map[string]interface{})
	secrets := taskMap["secrets"].([]interface{})
	if len(secrets) != 2 {
		t.Errorf("expected 2 secrets, got %d", len(secrets))
	}
}

func TestSecretsMethod(t *testing.T) {
	p := New()
	p.Task("deploy").Run("./deploy.sh").Secrets("GITHUB_TOKEN", "NPM_TOKEN", "AWS_KEY")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	taskMap := result["tasks"].([]interface{})[0].(map[string]interface{})
	secrets := taskMap["secrets"].([]interface{})
	if len(secrets) != 3 {
		t.Errorf("expected 3 secrets, got %d", len(secrets))
	}
}

func TestSecretNotSet(t *testing.T) {
	p := New()
	p.Task("test").Run("go test")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	taskMap := result["tasks"].([]interface{})[0].(map[string]interface{})
	if _, ok := taskMap["secrets"]; ok {
		t.Error("expected secrets to be omitted when not set")
	}
}

func TestSecretEmptyPanics(t *testing.T) {
	defer func() {
		if r := recover(); r == nil {
			t.Error("expected panic for empty secret name")
		}
	}()

	p := New()
	p.Task("deploy").Run("./deploy.sh").Secret("")
}

// ----- MATRIX TESTS -----

func TestMatrixSingleDimension(t *testing.T) {
	p := New()
	p.Task("test").Run("cargo test").Matrix("rust_version", "1.70", "1.75", "1.80")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	taskMap := result["tasks"].([]interface{})[0].(map[string]interface{})
	matrix := taskMap["matrix"].(map[string]interface{})
	versions := matrix["rust_version"].([]interface{})
	if len(versions) != 3 {
		t.Errorf("expected 3 versions, got %d", len(versions))
	}
}

func TestMatrixMultipleDimensions(t *testing.T) {
	p := New()
	p.Task("test").Run("cargo test").
		Matrix("rust_version", "1.70", "1.75").
		Matrix("os", "ubuntu", "macos")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	taskMap := result["tasks"].([]interface{})[0].(map[string]interface{})
	matrix := taskMap["matrix"].(map[string]interface{})
	if len(matrix) != 2 {
		t.Errorf("expected 2 dimensions, got %d", len(matrix))
	}
}

func TestMatrixNotSet(t *testing.T) {
	p := New()
	p.Task("test").Run("go test")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	taskMap := result["tasks"].([]interface{})[0].(map[string]interface{})
	if _, ok := taskMap["matrix"]; ok {
		t.Error("expected matrix to be omitted when not set")
	}
}

func TestMatrixEmptyKeyPanics(t *testing.T) {
	defer func() {
		if r := recover(); r == nil {
			t.Error("expected panic for empty matrix key")
		}
	}()

	p := New()
	p.Task("test").Run("go test").Matrix("", "value")
}

func TestMatrixEmptyValuesPanics(t *testing.T) {
	defer func() {
		if r := recover(); r == nil {
			t.Error("expected panic for empty matrix values")
		}
	}()

	p := New()
	p.Task("test").Run("go test").Matrix("key")
}

// ----- SERVICE TESTS -----

func TestServiceSingle(t *testing.T) {
	p := New()
	p.Task("test").Run("cargo test").Service("postgres:15", "db")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	taskMap := result["tasks"].([]interface{})[0].(map[string]interface{})
	services := taskMap["services"].([]interface{})
	if len(services) != 1 {
		t.Errorf("expected 1 service, got %d", len(services))
	}
	svc := services[0].(map[string]interface{})
	if svc["image"] != "postgres:15" {
		t.Errorf("expected postgres:15, got %v", svc["image"])
	}
	if svc["name"] != "db" {
		t.Errorf("expected db, got %v", svc["name"])
	}
}

func TestServiceMultiple(t *testing.T) {
	p := New()
	p.Task("test").Run("cargo test").Service("postgres:15", "db").Service("redis:7", "cache")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	taskMap := result["tasks"].([]interface{})[0].(map[string]interface{})
	services := taskMap["services"].([]interface{})
	if len(services) != 2 {
		t.Errorf("expected 2 services, got %d", len(services))
	}
}

func TestServiceNotSet(t *testing.T) {
	p := New()
	p.Task("test").Run("go test")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	taskMap := result["tasks"].([]interface{})[0].(map[string]interface{})
	if _, ok := taskMap["services"]; ok {
		t.Error("expected services to be omitted when not set")
	}
}

func TestServiceEmptyImagePanics(t *testing.T) {
	defer func() {
		if r := recover(); r == nil {
			t.Error("expected panic for empty service image")
		}
	}()

	p := New()
	p.Task("test").Run("go test").Service("", "db")
}

func TestServiceEmptyNamePanics(t *testing.T) {
	defer func() {
		if r := recover(); r == nil {
			t.Error("expected panic for empty service name")
		}
	}()

	p := New()
	p.Task("test").Run("go test").Service("postgres:15", "")
}

// ----- CYCLE DETECTION TESTS -----

func TestCycleSelfReference(t *testing.T) {
	// A task that depends on itself: A -> A
	p := New()
	p.Task("build").Run("go build").After("build")

	_, err := emitJSON(p)
	if err == nil {
		t.Error("expected error for self-referencing dependency")
	}
	if err != nil && !containsCycleError(err) {
		t.Errorf("expected cycle error, got: %v", err)
	}
}

func TestCycleDirectTwoTasks(t *testing.T) {
	// Direct cycle between two tasks: A -> B -> A
	p := New()
	p.Task("a").Run("echo a").After("b")
	p.Task("b").Run("echo b").After("a")

	_, err := emitJSON(p)
	if err == nil {
		t.Error("expected error for direct cycle between two tasks")
	}
	if err != nil && !containsCycleError(err) {
		t.Errorf("expected cycle error, got: %v", err)
	}
}

func TestCycleIndirectThreeTasks(t *testing.T) {
	// Indirect cycle: A -> B -> C -> A
	p := New()
	p.Task("a").Run("echo a").After("b")
	p.Task("b").Run("echo b").After("c")
	p.Task("c").Run("echo c").After("a")

	_, err := emitJSON(p)
	if err == nil {
		t.Error("expected error for indirect cycle among three tasks")
	}
	if err != nil && !containsCycleError(err) {
		t.Errorf("expected cycle error, got: %v", err)
	}
}

func TestCycleLongerChain(t *testing.T) {
	// Longer cycle: A -> B -> C -> D -> E -> A
	p := New()
	p.Task("a").Run("echo a").After("b")
	p.Task("b").Run("echo b").After("c")
	p.Task("c").Run("echo c").After("d")
	p.Task("d").Run("echo d").After("e")
	p.Task("e").Run("echo e").After("a")

	_, err := emitJSON(p)
	if err == nil {
		t.Error("expected error for longer cycle chain")
	}
	if err != nil && !containsCycleError(err) {
		t.Errorf("expected cycle error, got: %v", err)
	}
}

func TestCycleInComplexGraph(t *testing.T) {
	// Complex graph with a cycle hidden among valid dependencies
	// Valid: test, lint have no deps
	// Valid: build depends on test, lint
	// Cycle: deploy -> verify -> deploy
	p := New()
	p.Task("test").Run("go test")
	p.Task("lint").Run("go vet")
	p.Task("build").Run("go build").After("test", "lint")
	p.Task("deploy").Run("./deploy.sh").After("build", "verify")
	p.Task("verify").Run("./verify.sh").After("deploy")

	_, err := emitJSON(p)
	if err == nil {
		t.Error("expected error for cycle in complex graph")
	}
	if err != nil && !containsCycleError(err) {
		t.Errorf("expected cycle error, got: %v", err)
	}
}

func TestCycleErrorShowsPath(t *testing.T) {
	// Verify the error message includes the cycle path
	p := New()
	p.Task("a").Run("echo a").After("b")
	p.Task("b").Run("echo b").After("a")

	_, err := emitJSON(p)
	if err == nil {
		t.Fatal("expected error for cycle")
	}

	errStr := err.Error()
	// Error should mention both tasks in the cycle
	if !strings.Contains(errStr, "a") || !strings.Contains(errStr, "b") {
		t.Errorf("cycle error should mention tasks in cycle, got: %v", errStr)
	}
}

func TestNoCycleValidDAG(t *testing.T) {
	// Valid DAG with no cycles - should succeed
	// build depends on test, lint; deploy depends on build
	p := New()
	p.Task("test").Run("go test")
	p.Task("lint").Run("go vet")
	p.Task("build").Run("go build").After("test", "lint")
	p.Task("deploy").Run("./deploy.sh").After("build")

	_, err := emitJSON(p)
	if err != nil {
		t.Errorf("valid DAG should not error: %v", err)
	}
}

func TestNoCycleDiamondPattern(t *testing.T) {
	// Diamond pattern: b -> a, c -> a, d -> b, d -> c
	// (b,c depend on a; d depends on b,c; execution: a then b,c then d)
	p := New()
	p.Task("a").Run("echo a")
	p.Task("b").Run("echo b").After("a")
	p.Task("c").Run("echo c").After("a")
	p.Task("d").Run("echo d").After("b", "c")

	_, err := emitJSON(p)
	if err != nil {
		t.Errorf("diamond pattern should not error: %v", err)
	}
}

func TestNoCycleMultipleRoots(t *testing.T) {
	// Multiple independent roots converging
	p := New()
	p.Task("a").Run("echo a")
	p.Task("b").Run("echo b")
	p.Task("c").Run("echo c")
	p.Task("final").Run("echo final").After("a", "b", "c")

	_, err := emitJSON(p)
	if err != nil {
		t.Errorf("multiple roots should not error: %v", err)
	}
}

// Helper to check if error is a cycle error
func containsCycleError(err error) bool {
	if err == nil {
		return false
	}
	s := err.Error()
	return strings.Contains(s, "cycle") || strings.Contains(s, "circular")
}

// ----- NODE REQUIREMENTS TESTS -----

func TestRequiresSingleLabel(t *testing.T) {
	p := New()
	p.Task("build").Run("docker build .").Requires("docker")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatalf("emit failed: %v", err)
	}

	tasks := result["tasks"].([]interface{})
	task := tasks[0].(map[string]interface{})

	requires, ok := task["requires"].([]interface{})
	if !ok {
		t.Fatal("requires field not found or wrong type")
	}
	if len(requires) != 1 || requires[0] != "docker" {
		t.Errorf("expected [docker], got %v", requires)
	}
}

func TestRequiresMultipleLabels(t *testing.T) {
	p := New()
	p.Task("train").Run("python train.py").Requires("gpu", "docker")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatalf("emit failed: %v", err)
	}

	tasks := result["tasks"].([]interface{})
	task := tasks[0].(map[string]interface{})

	requires, ok := task["requires"].([]interface{})
	if !ok {
		t.Fatal("requires field not found or wrong type")
	}
	if len(requires) != 2 {
		t.Errorf("expected 2 labels, got %d", len(requires))
	}
}

func TestRequiresChaining(t *testing.T) {
	p := New()
	p.Task("build").Run("make").Requires("docker").Container("golang:1.21")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatalf("emit failed: %v", err)
	}

	tasks := result["tasks"].([]interface{})
	task := tasks[0].(map[string]interface{})

	// Both requires and container should be set
	if _, ok := task["requires"]; !ok {
		t.Error("requires field not found")
	}
	if task["container"] != "golang:1.21" {
		t.Error("container field not set correctly")
	}
}

func TestRequiresOmittedWhenEmpty(t *testing.T) {
	p := New()
	p.Task("test").Run("go test")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatalf("emit failed: %v", err)
	}

	tasks := result["tasks"].([]interface{})
	task := tasks[0].(map[string]interface{})

	// requires should be omitted (not present), not an empty array
	if _, ok := task["requires"]; ok {
		t.Error("requires should be omitted when empty")
	}
}

// =============================================================================
// K8S OPTIONS TESTS (Minimal API)
// =============================================================================

func TestK8sDefaults_AppliedToAllTasks(t *testing.T) {
	p := New(WithK8sDefaults(K8sOptions{
		Memory: "2Gi",
		CPU:    "1",
	}))

	p.Task("test").Run("go test")
	p.Task("build").Run("go build")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatalf("emit failed: %v", err)
	}

	tasks := result["tasks"].([]interface{})
	for _, task := range tasks {
		taskMap := task.(map[string]interface{})
		k8s := taskMap["k8s"].(map[string]interface{})
		if k8s["memory"] != "2Gi" {
			t.Errorf("task %s: expected memory '2Gi', got %v", taskMap["name"], k8s["memory"])
		}
		if k8s["cpu"] != "1" {
			t.Errorf("task %s: expected cpu '1', got %v", taskMap["name"], k8s["cpu"])
		}
	}
}

func TestK8sDefaults_TaskOverrides(t *testing.T) {
	p := New(WithK8sDefaults(K8sOptions{
		Memory: "2Gi",
		CPU:    "1",
	}))

	p.Task("small").Run("echo small")
	p.Task("heavy").Run("heavy-job").K8s(K8sOptions{
		Memory: "32Gi",
	})

	result, err := emitJSON(p)
	if err != nil {
		t.Fatalf("emit failed: %v", err)
	}

	tasks := result["tasks"].([]interface{})
	for _, task := range tasks {
		taskMap := task.(map[string]interface{})
		k8s := taskMap["k8s"].(map[string]interface{})

		if taskMap["name"] == "small" {
			if k8s["memory"] != "2Gi" {
				t.Errorf("small task: expected memory '2Gi', got %v", k8s["memory"])
			}
			if k8s["cpu"] != "1" {
				t.Errorf("small task: expected cpu '1', got %v", k8s["cpu"])
			}
		}

		if taskMap["name"] == "heavy" {
			if k8s["memory"] != "32Gi" {
				t.Errorf("heavy task: expected memory '32Gi', got %v", k8s["memory"])
			}
			// CPU should be inherited from defaults
			if k8s["cpu"] != "1" {
				t.Errorf("heavy task: expected cpu '1' (inherited), got %v", k8s["cpu"])
			}
		}
	}
}

func TestK8sDefaults_NoDefaultsNoK8s(t *testing.T) {
	p := New() // No K8s defaults

	p.Task("test").Run("go test")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatalf("emit failed: %v", err)
	}

	tasks := result["tasks"].([]interface{})
	taskMap := tasks[0].(map[string]interface{})

	// Should have no k8s field when neither defaults nor task options set
	if _, exists := taskMap["k8s"]; exists {
		t.Error("expected no k8s field when no defaults or task options set")
	}
}

func TestK8s_GPU(t *testing.T) {
	p := New()
	p.Task("train").Run("python train.py").K8s(K8sOptions{
		Memory: "32Gi",
		GPU:    1,
	})

	result, err := emitJSON(p)
	if err != nil {
		t.Fatalf("emit failed: %v", err)
	}

	tasks := result["tasks"].([]interface{})
	taskMap := tasks[0].(map[string]interface{})
	k8s := taskMap["k8s"].(map[string]interface{})

	if k8s["gpu"] != float64(1) {
		t.Errorf("expected gpu=1, got %v", k8s["gpu"])
	}
}

func TestK8sRaw_EscapeHatch(t *testing.T) {
	p := New()
	p.Task("gpu-task").
		Run("python train.py").
		K8s(K8sOptions{Memory: "32Gi", GPU: 1}).
		K8sRaw(`{"nodeSelector": {"gpu": "true"}}`)

	result, err := emitJSON(p)
	if err != nil {
		t.Fatalf("emit failed: %v", err)
	}

	tasks := result["tasks"].([]interface{})
	taskMap := tasks[0].(map[string]interface{})
	k8s := taskMap["k8s"].(map[string]interface{})

	if k8s["memory"] != "32Gi" {
		t.Errorf("expected memory='32Gi', got %v", k8s["memory"])
	}
	if k8s["raw"] != `{"nodeSelector": {"gpu": "true"}}` {
		t.Errorf("expected raw JSON, got %v", k8s["raw"])
	}
}

// =============================================================================
// K8S VALIDATION TESTS
// =============================================================================

func TestK8sValidation_ValidMemoryFormats(t *testing.T) {
	validMemory := []string{"512Mi", "4Gi", "1Ti", "100Ki", "1024", "1G", "500M"}

	for _, mem := range validMemory {
		p := New()
		p.Task("test").Run("echo test").K8s(K8sOptions{Memory: mem})

		_, err := emitJSON(p)
		if err != nil {
			t.Errorf("expected %q to be valid memory, got error: %v", mem, err)
		}
	}
}

func TestK8sValidation_InvalidMemoryFormats(t *testing.T) {
	invalidMemory := []struct {
		value    string
		contains string // expected error substring
	}{
		{"32gb", "did you mean 'Gi'"},
		{"512mb", "did you mean 'Mi'"},
		{"1kb", "did you mean 'Ki'"},
		{"4GB", "did you mean 'Gi'"},
		{"lots", "invalid memory format"},
	}

	for _, tc := range invalidMemory {
		p := New()
		p.Task("test").Run("echo test").K8s(K8sOptions{Memory: tc.value})

		_, err := emitJSON(p)
		if err == nil {
			t.Errorf("expected %q to fail validation", tc.value)
			continue
		}
		if !strings.Contains(err.Error(), tc.contains) {
			t.Errorf("expected error for %q to contain %q, got: %v", tc.value, tc.contains, err)
		}
	}
}

func TestK8sValidation_ValidCPUFormats(t *testing.T) {
	validCPU := []string{"100m", "500m", "1", "2", "0.5", "1.5", "2000m"}

	for _, cpu := range validCPU {
		p := New()
		p.Task("test").Run("echo test").K8s(K8sOptions{CPU: cpu})

		_, err := emitJSON(p)
		if err != nil {
			t.Errorf("expected %q to be valid CPU, got error: %v", cpu, err)
		}
	}
}

func TestK8sValidation_InvalidCPUFormats(t *testing.T) {
	invalidCPU := []string{"100cores", "2 cores", "fast"}

	for _, cpu := range invalidCPU {
		p := New()
		p.Task("test").Run("echo test").K8s(K8sOptions{CPU: cpu})

		_, err := emitJSON(p)
		if err == nil {
			t.Errorf("expected %q to fail validation", cpu)
		}
	}
}
