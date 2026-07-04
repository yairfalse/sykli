use Sykli

pipeline do
  task "implement" do
    run("go test ./...")
    task_type(:test)
    success_criteria([exit_code(0)])
    evidence_required([file_evidence_non_empty("coverage", "coverage.out")])
    actor(:agent, "claude")
    mandate(["sdk/**", "tests/conformance/**"])
  end
end
