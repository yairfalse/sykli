#!/usr/bin/env elixir

# CI pipeline for an Elixir project
Mix.install([{:sykli, "~> 0.3.0"}])

Code.eval_string("""
use Sykli

pipeline do
  task "deps" do
    run "mix deps.get"
    inputs ["mix.exs", "mix.lock"]
  end

  task "compile" do
    run "mix compile --warnings-as-errors"
    after_ ["deps"]
    inputs ["**/*.ex", "mix.exs"]
  end

  task "test" do
    run "mix test"
    after_ ["compile"]
    inputs ["**/*.ex", "**/*.exs", "mix.exs"]
  end

  task "credo" do
    run "mix credo --strict"
    after_ ["deps"]
    inputs ["**/*.ex", "**/*.exs"]
  end

  task "format" do
    run "mix format --check-formatted"
    inputs ["**/*.ex", "**/*.exs"]
  end

  task "dialyzer" do
    run "mix dialyzer"
    after_ ["compile"]
    inputs ["**/*.ex", "mix.exs"]
  end
end
""")
