use Sykli

pipeline do
  task "docs" do
    run("make docs")
    actor(:human, "maintainer")
    mandate(["docs/**", "README.md"], diff_lines: 200, wall_clock_ms: 900_000, network: false)
  end
end
