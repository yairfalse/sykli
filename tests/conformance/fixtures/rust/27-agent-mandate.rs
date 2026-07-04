use sykli::{Actor, ActorKind, EvidenceRequirement, Mandate, Pipeline, SuccessCriterion, TaskType};

fn main() {
    let mut p = Pipeline::new();
    p.task("implement")
        .run("go test ./...")
        .task_type(TaskType::Test)
        .success_criteria(&[SuccessCriterion::ExitCode(0)])
        .evidence_required(&[EvidenceRequirement::file_non_empty(
            "coverage",
            "coverage.out",
        )])
        .actor(Actor::new(ActorKind::Agent).id("claude"))
        .mandate(Mandate::new(&["sdk/**", "tests/conformance/**"]));
    p.emit();
}
