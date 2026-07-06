IO.puts(
  ~s({"version":"5","tasks":[{"name":"scoped","command":"mkdir -p other && printf x > other/file.txt","success_criteria":[{"type":"exit_code","equals":0}],"evidence_required":[{"type":"file","name":"pipeline","ref_pattern":"sykli.exs"}],"actor":{"kind":"agent","id":"codex"},"mandate":{"scope":["allowed/**"]}}]})
)
