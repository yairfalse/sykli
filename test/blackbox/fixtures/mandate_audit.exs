IO.puts(
  ~s({"version":"5","tasks":[{"name":"audit-me","command":"true","success_criteria":[{"type":"exit_code","equals":0}],"evidence_required":[{"type":"file","name":"pipeline","ref_pattern":"sykli.exs"}],"actor":{"kind":"agent","id":"codex"},"mandate":{"scope":["**"],"budget":{"wall_clock_ms":1000}}}]})
)
