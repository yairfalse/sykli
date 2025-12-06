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
