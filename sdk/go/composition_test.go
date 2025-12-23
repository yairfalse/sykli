package sykli

import (
	"testing"
)

// =============================================================================
// TEMPLATE TESTS
// =============================================================================

func TestTemplateBasic(t *testing.T) {
	p := New()
	src := p.Dir(".")

	// Create a template with common configuration
	golang := p.Template("golang").
		Container("golang:1.21").
		Mount(src, "/src").
		Workdir("/src")

	// Task inherits from template
	p.Task("test").From(golang).Run("go test ./...")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	task := getTaskMap(result, "test")
	if task == nil {
		t.Fatal("task 'test' not found")
	}

	// Should have inherited container
	if task["container"] != "golang:1.21" {
		t.Errorf("expected container 'golang:1.21', got %v", task["container"])
	}

	// Should have inherited workdir
	if task["workdir"] != "/src" {
		t.Errorf("expected workdir '/src', got %v", task["workdir"])
	}

	// Should have inherited mount
	mounts := task["mounts"].([]interface{})
	if len(mounts) != 1 {
		t.Errorf("expected 1 mount, got %d", len(mounts))
	}
}

func TestTemplateWithCache(t *testing.T) {
	p := New()
	src := p.Dir(".")
	modCache := p.Cache("go-mod")

	golang := p.Template("golang").
		Container("golang:1.21").
		Mount(src, "/src").
		MountCache(modCache, "/go/pkg/mod").
		Workdir("/src")

	p.Task("test").From(golang).Run("go test")
	p.Task("build").From(golang).Run("go build")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	// Both tasks should have 2 mounts (dir + cache)
	for _, name := range []string{"test", "build"} {
		task := getTaskMap(result, name)
		mounts := task["mounts"].([]interface{})
		if len(mounts) != 2 {
			t.Errorf("task %s: expected 2 mounts, got %d", name, len(mounts))
		}
	}
}

func TestTemplateWithEnv(t *testing.T) {
	p := New()

	tmpl := p.Template("go-build").
		Container("golang:1.21").
		Env("CGO_ENABLED", "0").
		Env("GOOS", "linux")

	p.Task("build").From(tmpl).Run("go build")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	task := getTaskMap(result, "build")
	env := task["env"].(map[string]interface{})

	if env["CGO_ENABLED"] != "0" {
		t.Errorf("expected CGO_ENABLED=0, got %v", env["CGO_ENABLED"])
	}
	if env["GOOS"] != "linux" {
		t.Errorf("expected GOOS=linux, got %v", env["GOOS"])
	}
}

func TestTemplateOverride(t *testing.T) {
	p := New()

	tmpl := p.Template("base").
		Container("golang:1.21").
		Env("FOO", "from-template")

	// Task overrides the env var
	p.Task("test").From(tmpl).Env("FOO", "from-task").Run("echo $FOO")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	task := getTaskMap(result, "test")
	env := task["env"].(map[string]interface{})

	// Task-level should override template-level
	if env["FOO"] != "from-task" {
		t.Errorf("expected FOO=from-task (override), got %v", env["FOO"])
	}
}

func TestTemplateMultipleTasks(t *testing.T) {
	p := New()
	src := p.Dir(".")

	golang := p.Template("golang").
		Container("golang:1.21").
		Mount(src, "/src").
		Workdir("/src")

	p.Task("lint").From(golang).Run("go vet ./...")
	p.Task("test").From(golang).Run("go test ./...")
	p.Task("build").From(golang).Run("go build").After("lint", "test")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	tasks := result["tasks"].([]interface{})
	if len(tasks) != 3 {
		t.Errorf("expected 3 tasks, got %d", len(tasks))
	}

	// All should have same container
	for _, name := range []string{"lint", "test", "build"} {
		task := getTaskMap(result, name)
		if task["container"] != "golang:1.21" {
			t.Errorf("task %s: expected container golang:1.21, got %v", name, task["container"])
		}
	}
}

func TestTemplateNotInJSON(t *testing.T) {
	p := New()

	// Templates should NOT appear in JSON output
	p.Template("unused").Container("alpine")
	p.Task("test").Run("echo test")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	// Should not have any "templates" field in JSON
	if _, ok := result["templates"]; ok {
		t.Error("templates should not appear in JSON output")
	}
}

func TestEmptyTemplateNamePanics(t *testing.T) {
	defer func() {
		if r := recover(); r == nil {
			t.Error("expected panic for empty template name")
		}
	}()

	p := New()
	p.Template("")
}

// =============================================================================
// CHAIN COMBINATOR TESTS
// =============================================================================

func TestChainBasic(t *testing.T) {
	p := New()

	// Chain creates sequential dependencies: a → b → c
	p.Chain(
		p.Task("a").Run("echo a"),
		p.Task("b").Run("echo b"),
		p.Task("c").Run("echo c"),
	)

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	// a has no deps
	taskA := getTaskMap(result, "a")
	if deps := getDeps(taskA); len(deps) != 0 {
		t.Errorf("task a should have no deps, got %v", deps)
	}

	// b depends on a
	taskB := getTaskMap(result, "b")
	if deps := getDeps(taskB); len(deps) != 1 || deps[0] != "a" {
		t.Errorf("task b should depend on [a], got %v", deps)
	}

	// c depends on b
	taskC := getTaskMap(result, "c")
	if deps := getDeps(taskC); len(deps) != 1 || deps[0] != "b" {
		t.Errorf("task c should depend on [b], got %v", deps)
	}
}

func TestChainPreservesExistingDeps(t *testing.T) {
	p := New()

	// Task already has a dependency
	p.Task("prereq").Run("echo prereq")

	p.Chain(
		p.Task("a").Run("echo a").After("prereq"), // existing dep
		p.Task("b").Run("echo b"),
	)

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	// a should have prereq as dep (from After), NOT from chain
	taskA := getTaskMap(result, "a")
	deps := getDeps(taskA)
	if len(deps) != 1 || deps[0] != "prereq" {
		t.Errorf("task a should depend on [prereq], got %v", deps)
	}

	// b should depend on a (from chain)
	taskB := getTaskMap(result, "b")
	deps = getDeps(taskB)
	if len(deps) != 1 || deps[0] != "a" {
		t.Errorf("task b should depend on [a], got %v", deps)
	}
}

func TestChainSingleTask(t *testing.T) {
	p := New()

	// Chain with single task should work (no deps added)
	p.Chain(
		p.Task("only").Run("echo only"),
	)

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	task := getTaskMap(result, "only")
	if deps := getDeps(task); len(deps) != 0 {
		t.Errorf("single task in chain should have no deps, got %v", deps)
	}
}

// =============================================================================
// PARALLEL COMBINATOR TESTS
// =============================================================================

func TestParallelBasic(t *testing.T) {
	p := New()

	// Parallel creates a group that can be depended on
	p.Parallel("checks",
		p.Task("lint").Run("go vet"),
		p.Task("fmt").Run("gofmt -l ."),
		p.Task("test").Run("go test"),
	)

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	// All tasks should have no dependencies (they run in parallel)
	for _, name := range []string{"lint", "fmt", "test"} {
		task := getTaskMap(result, name)
		if deps := getDeps(task); len(deps) != 0 {
			t.Errorf("task %s should have no deps, got %v", name, deps)
		}
	}
}

func TestParallelAsDependency(t *testing.T) {
	p := New()

	// Create parallel group
	checks := p.Parallel("checks",
		p.Task("lint").Run("go vet"),
		p.Task("test").Run("go test"),
	)

	// Another task depends on the entire group
	p.Task("build").Run("go build").AfterGroup(checks)

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	// build should depend on BOTH lint and test
	task := getTaskMap(result, "build")
	deps := getDeps(task)

	if len(deps) != 2 {
		t.Errorf("build should have 2 deps, got %d: %v", len(deps), deps)
	}

	// Check both are present (order may vary)
	hasLint := false
	hasTest := false
	for _, d := range deps {
		if d == "lint" {
			hasLint = true
		}
		if d == "test" {
			hasTest = true
		}
	}
	if !hasLint || !hasTest {
		t.Errorf("build should depend on [lint, test], got %v", deps)
	}
}

func TestParallelAfterTask(t *testing.T) {
	p := New()

	p.Task("setup").Run("echo setup")

	// Parallel group that runs after setup
	p.Parallel("checks",
		p.Task("lint").Run("go vet"),
		p.Task("test").Run("go test"),
	).After("setup")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	// Both lint and test should depend on setup
	for _, name := range []string{"lint", "test"} {
		task := getTaskMap(result, name)
		deps := getDeps(task)
		if len(deps) != 1 || deps[0] != "setup" {
			t.Errorf("task %s should depend on [setup], got %v", name, deps)
		}
	}
}

func TestChainWithParallel(t *testing.T) {
	p := New()

	// Real-world pattern: parallel checks, then build, then deploy
	checks := p.Parallel("checks",
		p.Task("lint").Run("go vet"),
		p.Task("test").Run("go test"),
	)

	p.Chain(
		checks,
		p.Task("build").Run("go build"),
		p.Task("deploy").Run("./deploy.sh"),
	)

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	// lint and test have no deps
	for _, name := range []string{"lint", "test"} {
		task := getTaskMap(result, name)
		if deps := getDeps(task); len(deps) != 0 {
			t.Errorf("task %s should have no deps, got %v", name, deps)
		}
	}

	// build depends on both lint and test
	build := getTaskMap(result, "build")
	buildDeps := getDeps(build)
	if len(buildDeps) != 2 {
		t.Errorf("build should have 2 deps, got %v", buildDeps)
	}

	// deploy depends on build
	deploy := getTaskMap(result, "deploy")
	deployDeps := getDeps(deploy)
	if len(deployDeps) != 1 || deployDeps[0] != "build" {
		t.Errorf("deploy should depend on [build], got %v", deployDeps)
	}
}

// =============================================================================
// HELPER FUNCTIONS
// =============================================================================

func getTaskMap(result map[string]interface{}, name string) map[string]interface{} {
	tasks := result["tasks"].([]interface{})
	for _, t := range tasks {
		task := t.(map[string]interface{})
		if task["name"] == name {
			return task
		}
	}
	return nil
}

func getDeps(task map[string]interface{}) []string {
	if task == nil {
		return nil
	}
	deps, ok := task["depends_on"].([]interface{})
	if !ok {
		return []string{}
	}
	result := make([]string, len(deps))
	for i, d := range deps {
		result[i] = d.(string)
	}
	return result
}

// =============================================================================
// INPUT/OUTPUT BINDING TESTS
// =============================================================================

func TestInputFromBasic(t *testing.T) {
	p := New()

	// Build task produces an output
	p.Task("build").
		Run("go build -o /out/app").
		Output("binary", "/out/app")

	// Package task consumes the output
	p.Task("package").
		InputFrom("build", "binary", "/app").
		Run("docker build .")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	// Check package task has task_inputs
	pkg := getTaskMap(result, "package")
	inputs := pkg["task_inputs"].([]interface{})
	if len(inputs) != 1 {
		t.Fatalf("expected 1 task_input, got %d", len(inputs))
	}

	input := inputs[0].(map[string]interface{})
	if input["from_task"] != "build" {
		t.Errorf("expected from_task='build', got %v", input["from_task"])
	}
	if input["output"] != "binary" {
		t.Errorf("expected output='binary', got %v", input["output"])
	}
	if input["dest"] != "/app" {
		t.Errorf("expected dest='/app', got %v", input["dest"])
	}
}

func TestInputFromAutoAddsDependency(t *testing.T) {
	p := New()

	p.Task("build").Run("go build").Output("binary", "./app")
	// InputFrom should automatically add dependency on build
	p.Task("package").InputFrom("build", "binary", "/app").Run("docker build")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	pkg := getTaskMap(result, "package")
	deps := getDeps(pkg)

	// Should have build as dependency
	if len(deps) != 1 || deps[0] != "build" {
		t.Errorf("expected deps=['build'], got %v", deps)
	}
}

func TestInputFromMultiple(t *testing.T) {
	p := New()

	// Two build tasks produce outputs
	p.Task("build-linux").Run("GOOS=linux go build -o app-linux").Output("binary", "./app-linux")
	p.Task("build-darwin").Run("GOOS=darwin go build -o app-darwin").Output("binary", "./app-darwin")

	// Package consumes both
	p.Task("package").
		InputFrom("build-linux", "binary", "/linux/app").
		InputFrom("build-darwin", "binary", "/darwin/app").
		Run("tar czf release.tar.gz /linux /darwin")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	pkg := getTaskMap(result, "package")
	inputs := pkg["task_inputs"].([]interface{})
	if len(inputs) != 2 {
		t.Fatalf("expected 2 task_inputs, got %d", len(inputs))
	}

	// Should depend on both
	deps := getDeps(pkg)
	if len(deps) != 2 {
		t.Errorf("expected 2 deps, got %v", deps)
	}
}

func TestInputFromWithExistingDeps(t *testing.T) {
	p := New()

	p.Task("setup").Run("echo setup")
	p.Task("build").Run("go build").Output("binary", "./app")
	// Task has explicit dep AND input dep
	p.Task("package").
		After("setup").
		InputFrom("build", "binary", "/app").
		Run("docker build")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	pkg := getTaskMap(result, "package")
	deps := getDeps(pkg)

	// Should have both setup and build
	if len(deps) != 2 {
		t.Errorf("expected 2 deps, got %v", deps)
	}

	hasSetup := false
	hasBuild := false
	for _, d := range deps {
		if d == "setup" {
			hasSetup = true
		}
		if d == "build" {
			hasBuild = true
		}
	}
	if !hasSetup || !hasBuild {
		t.Errorf("expected deps to contain setup and build, got %v", deps)
	}
}

func TestInputFromNoDuplicateDeps(t *testing.T) {
	p := New()

	p.Task("build").Run("go build").Output("binary", "./app")
	// Explicit dep on build AND InputFrom build - should not duplicate
	p.Task("package").
		After("build").
		InputFrom("build", "binary", "/app").
		Run("docker build")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	pkg := getTaskMap(result, "package")
	deps := getDeps(pkg)

	// Should have only one "build" dep, not duplicated
	if len(deps) != 1 {
		t.Errorf("expected 1 dep (no duplicate), got %v", deps)
	}
}

func TestInputFromChainPattern(t *testing.T) {
	p := New()

	// Common pattern: build → test → package → deploy
	// Each step passes artifacts to the next

	p.Task("build").
		Run("go build -o /out/app").
		Output("binary", "/out/app")

	p.Task("test").
		InputFrom("build", "binary", "/app").
		Run("./app --test").
		Output("report", "/out/report.xml")

	p.Task("package").
		InputFrom("build", "binary", "/app").
		InputFrom("test", "report", "/report.xml").
		Run("docker build")

	result, err := emitJSON(p)
	if err != nil {
		t.Fatal(err)
	}

	// Verify chain: build has no deps, test depends on build, package depends on both
	build := getTaskMap(result, "build")
	if len(getDeps(build)) != 0 {
		t.Error("build should have no deps")
	}

	test := getTaskMap(result, "test")
	testDeps := getDeps(test)
	if len(testDeps) != 1 || testDeps[0] != "build" {
		t.Errorf("test should depend on build, got %v", testDeps)
	}

	pkg := getTaskMap(result, "package")
	pkgDeps := getDeps(pkg)
	if len(pkgDeps) != 2 {
		t.Errorf("package should depend on build and test, got %v", pkgDeps)
	}
}
