from sykli import Pipeline, actor, exit_code, file_evidence_non_empty, mandate

p = Pipeline()
p.task("implement").run("go test ./...").task_type("test").success_criteria([
    exit_code(0),
]).evidence_required([
    file_evidence_non_empty("coverage", "coverage.out"),
]).actor(actor("agent", "claude")).mandate(
    mandate(["sdk/**", "tests/conformance/**"])
)
p.emit()
