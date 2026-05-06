from sykli import Pipeline

p = Pipeline()
p.task("test").run("go test ./...").task_type("test").success_criteria([
    {"type": "exit_code", "equals": 0},
    {"type": "file_exists", "path": "coverage.out"},
])
p.task("package").run("go build -o dist/app ./...").task_type("package").success_criteria([
    {"type": "file_non_empty", "path": "dist/app"},
]).after("test")
p.emit()
