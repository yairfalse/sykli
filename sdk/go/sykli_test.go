package sykli

import (
	"bytes"
	"encoding/json"
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
