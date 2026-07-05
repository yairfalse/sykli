from sykli import Pipeline, actor, mandate

p = Pipeline()
p.task("docs").run("make docs").actor(actor("human", "maintainer")).mandate(
    mandate(["docs/**", "README.md"], diff_lines=200, wall_clock_ms=900000, network=False)
)
p.emit()
