use sykli::{Pipeline, TaskType};

fn main() {
    let mut p = Pipeline::new();

    p.task("build")
        .run("go build ./...")
        .task_type(TaskType::Build);
    p.task("test")
        .run("go test ./...")
        .task_type(TaskType::Test)
        .after(&["build"]);

    p.emit();
}
