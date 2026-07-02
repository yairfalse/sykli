gate = Mix.Project.config()[:aliases][:gate] || []
doc = File.read!("../docs/guardrails-conformance.md")

missing =
  Enum.reject(gate, fn command ->
    String.contains?(doc, "`#{command}`")
  end)

if missing != [] do
  IO.puts(:stderr, "guardrails declaration missing gate commands: #{Enum.join(missing, ", ")}")
  System.halt(1)
end

unless String.contains?(doc, "`ERL_COMPILER_OPTIONS=[deterministic]`") do
  IO.puts(:stderr, "guardrails declaration missing deterministic compiler option")
  System.halt(1)
end
