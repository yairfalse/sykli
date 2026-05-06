use sykli::{Pipeline, SuccessCriterion, TaskType};

fn main() {
    let mut p = Pipeline::new();
    p.task("test")
        .run("go test ./...")
        .task_type(TaskType::Test)
        .success_criteria(&[
            SuccessCriterion::ExitCode(0),
            SuccessCriterion::FileExists("coverage.out".into()),
        ]);
    p.task("package")
        .run("go build -o dist/app ./...")
        .task_type(TaskType::Package)
        .success_criteria(&[SuccessCriterion::FileNonEmpty("dist/app".into())])
        .after(&["test"]);
    p.emit();
}
