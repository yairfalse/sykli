use sykli::{Pipeline, Criticality, OnFailAction, SelectMode};

fn main() {
    let mut p = Pipeline::new();
    p.task("test-auth").run("pytest tests/auth/")
        .inputs(&["src/auth/**/*.py", "tests/auth/**/*.py"])
        .covers(&["src/auth/*"])
        .intent("unit tests for auth module")
        .set_criticality(Criticality::High)
        .on_fail(OnFailAction::Analyze)
        .select_mode(SelectMode::Smart);
    p.emit();
}
