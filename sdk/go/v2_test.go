package sykli

import (
	"testing"
)

func TestDirResource(t *testing.T) {
	p := New()
	dir := p.Dir(".")

	if dir.ID() != "src:." {
		t.Errorf("expected ID 'src:.', got %q", dir.ID())
	}
}

func TestDirWithGlob(t *testing.T) {
	p := New()
	dir := p.Dir(".").Glob("**/*.go", "go.mod")

	if len(dir.globs) != 2 {
		t.Errorf("expected 2 globs, got %d", len(dir.globs))
	}
}

func TestCacheResource(t *testing.T) {
	p := New()
	cache := p.Cache("go-mod")

	if cache.ID() != "go-mod" {
		t.Errorf("expected ID 'go-mod', got %q", cache.ID())
	}
}

func TestContainerTask(t *testing.T) {
	p := New()
	p.Task("test").
		Container("golang:1.21").
		Run("go test ./...")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	tasks := result["tasks"].([]interface{})
	task := tasks[0].(map[string]interface{})

	if task["container"] != "golang:1.21" {
		t.Errorf("expected container 'golang:1.21', got %v", task["container"])
	}
}

func TestContainerWithMount(t *testing.T) {
	p := New()
	src := p.Dir(".")

	p.Task("test").
		Container("golang:1.21").
		Mount(src, "/src").
		Run("go test")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	tasks := result["tasks"].([]interface{})
	task := tasks[0].(map[string]interface{})
	mounts := task["mounts"].([]interface{})

	if len(mounts) != 1 {
		t.Fatalf("expected 1 mount, got %d", len(mounts))
	}

	mount := mounts[0].(map[string]interface{})
	if mount["resource"] != "src:." {
		t.Errorf("expected resource 'src:.', got %v", mount["resource"])
	}
	if mount["path"] != "/src" {
		t.Errorf("expected path '/src', got %v", mount["path"])
	}
	if mount["type"] != "directory" {
		t.Errorf("expected type 'directory', got %v", mount["type"])
	}
}

func TestContainerWithCache(t *testing.T) {
	p := New()
	cache := p.Cache("go-mod")

	p.Task("test").
		Container("golang:1.21").
		MountCache(cache, "/go/pkg/mod").
		Run("go test")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	tasks := result["tasks"].([]interface{})
	task := tasks[0].(map[string]interface{})
	mounts := task["mounts"].([]interface{})
	mount := mounts[0].(map[string]interface{})

	if mount["resource"] != "go-mod" {
		t.Errorf("expected resource 'go-mod', got %v", mount["resource"])
	}
	if mount["type"] != "cache" {
		t.Errorf("expected type 'cache', got %v", mount["type"])
	}
}

func TestContainerWithWorkdir(t *testing.T) {
	p := New()
	p.Task("test").
		Container("golang:1.21").
		Workdir("/src").
		Run("go test")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	tasks := result["tasks"].([]interface{})
	task := tasks[0].(map[string]interface{})

	if task["workdir"] != "/src" {
		t.Errorf("expected workdir '/src', got %v", task["workdir"])
	}
}

func TestContainerWithEnv(t *testing.T) {
	p := New()
	p.Task("build").
		Container("golang:1.21").
		Env("CGO_ENABLED", "0").
		Env("GOOS", "linux").
		Run("go build")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	tasks := result["tasks"].([]interface{})
	task := tasks[0].(map[string]interface{})
	env := task["env"].(map[string]interface{})

	if env["CGO_ENABLED"] != "0" {
		t.Errorf("expected CGO_ENABLED='0', got %v", env["CGO_ENABLED"])
	}
	if env["GOOS"] != "linux" {
		t.Errorf("expected GOOS='linux', got %v", env["GOOS"])
	}
}

func TestTaskOutput(t *testing.T) {
	p := New()
	p.Task("build").
		Run("go build -o app").
		Output("binary", "./app")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	tasks := result["tasks"].([]interface{})
	task := tasks[0].(map[string]interface{})
	outputs := task["outputs"].(map[string]interface{})

	if outputs["binary"] != "./app" {
		t.Errorf("expected output binary='./app', got %v", outputs["binary"])
	}
}

func TestFullContainerWorkflow(t *testing.T) {
	p := New()
	src := p.Dir(".")
	goModCache := p.Cache("go-mod")
	goBuildCache := p.Cache("go-build")

	p.Task("lint").
		Container("golang:1.21").
		Mount(src, "/src").
		MountCache(goModCache, "/go/pkg/mod").
		Workdir("/src").
		Run("go vet ./...")

	p.Task("test").
		Container("golang:1.21").
		Mount(src, "/src").
		MountCache(goModCache, "/go/pkg/mod").
		MountCache(goBuildCache, "/root/.cache/go-build").
		Workdir("/src").
		Run("go test ./...")

	p.Task("build").
		Container("golang:1.21").
		Mount(src, "/src").
		MountCache(goModCache, "/go/pkg/mod").
		MountCache(goBuildCache, "/root/.cache/go-build").
		Workdir("/src").
		Env("CGO_ENABLED", "0").
		Run("go build -o ./app .").
		Output("binary", "./app").
		After("lint", "test")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	// Check version is 2
	if result["version"] != "2" {
		t.Errorf("expected version '2', got %v", result["version"])
	}

	// Check resources
	resources := result["resources"].(map[string]interface{})
	if len(resources) != 3 {
		t.Errorf("expected 3 resources, got %d", len(resources))
	}

	// Check tasks
	tasks := result["tasks"].([]interface{})
	if len(tasks) != 3 {
		t.Errorf("expected 3 tasks, got %d", len(tasks))
	}
}

// Test backward compatibility
func TestSimpleTaskStillWorks(t *testing.T) {
	p := New()
	p.Task("test").Run("go test ./...")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	if result["version"] != "1" {
		t.Errorf("simple task should produce version 1, got %v", result["version"])
	}
}

func TestPresetsStillWork(t *testing.T) {
	p := New()
	p.Go().Test()
	p.Go().Build("./app").After("test")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	tasks := result["tasks"].([]interface{})
	if len(tasks) != 2 {
		t.Errorf("expected 2 tasks, got %d", len(tasks))
	}
}

func TestInputsStillWork(t *testing.T) {
	p := New()
	p.Task("test").Run("go test").Inputs("**/*.go", "go.mod")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	tasks := result["tasks"].([]interface{})
	task := tasks[0].(map[string]interface{})
	inputs := task["inputs"].([]interface{})

	if len(inputs) != 2 {
		t.Errorf("expected 2 inputs, got %d", len(inputs))
	}
}

// Validation tests

func TestEmptyDirPathPanics(t *testing.T) {
	defer func() {
		if r := recover(); r == nil {
			t.Error("expected panic for empty directory path")
		}
	}()
	p := New()
	p.Dir("")
}

func TestEmptyCacheNamePanics(t *testing.T) {
	defer func() {
		if r := recover(); r == nil {
			t.Error("expected panic for empty cache name")
		}
	}()
	p := New()
	p.Cache("")
}

func TestEmptyCommandPanics(t *testing.T) {
	defer func() {
		if r := recover(); r == nil {
			t.Error("expected panic for empty command")
		}
	}()
	p := New()
	p.Task("test").Run("")
}

func TestEmptyContainerImagePanics(t *testing.T) {
	defer func() {
		if r := recover(); r == nil {
			t.Error("expected panic for empty container image")
		}
	}()
	p := New()
	p.Task("test").Container("")
}

func TestNilDirectoryMountPanics(t *testing.T) {
	defer func() {
		if r := recover(); r == nil {
			t.Error("expected panic for nil directory")
		}
	}()
	p := New()
	p.Task("test").Mount(nil, "/src")
}

func TestNilCacheMountPanics(t *testing.T) {
	defer func() {
		if r := recover(); r == nil {
			t.Error("expected panic for nil cache")
		}
	}()
	p := New()
	p.Task("test").MountCache(nil, "/cache")
}

func TestRelativeMountPathPanics(t *testing.T) {
	defer func() {
		if r := recover(); r == nil {
			t.Error("expected panic for relative mount path")
		}
	}()
	p := New()
	dir := p.Dir(".")
	p.Task("test").Mount(dir, "relative/path")
}

func TestEmptyEnvKeyPanics(t *testing.T) {
	defer func() {
		if r := recover(); r == nil {
			t.Error("expected panic for empty env key")
		}
	}()
	p := New()
	p.Task("test").Env("", "value")
}

func TestV2JSONStructure(t *testing.T) {
	p := New()
	src := p.Dir(".")
	cache := p.Cache("test-cache")

	p.Task("test").
		Container("alpine").
		Mount(src, "/src").
		MountCache(cache, "/cache").
		Run("echo test")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	// Version should be 2
	if result["version"] != "2" {
		t.Errorf("expected version '2', got %v", result["version"])
	}

	// Resources should exist
	resources, ok := result["resources"].(map[string]interface{})
	if !ok {
		t.Fatal("resources should be a map")
	}

	// Check directory resource
	srcRes := resources["src:."].(map[string]interface{})
	if srcRes["type"] != "directory" {
		t.Errorf("expected type 'directory', got %v", srcRes["type"])
	}

	// Check cache resource
	cacheRes := resources["test-cache"].(map[string]interface{})
	if cacheRes["type"] != "cache" {
		t.Errorf("expected type 'cache', got %v", cacheRes["type"])
	}
}
