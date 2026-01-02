# Example 02: Input-Based Caching
#
# This example demonstrates:
# - `inputs` for content-addressed caching
# - `output` for declaring artifacts
# - `when_` for conditional execution
#
# Tasks with unchanged inputs are skipped on subsequent runs.
#
# Run with: elixir sykli.exs --emit | sykli run -

Mix.install([{:sykli, "~> 0.2"}])

use Sykli

pipeline do
  # Test task with input patterns
  # If **/*.ex files haven't changed, this task is skipped
  task "test" do
    run "mix test"
    inputs ["**/*.ex", "**/*.exs", "mix.exs", "mix.lock"]
  end

  # Build task with inputs and outputs
  # Skipped if inputs unchanged AND output exists
  task "build" do
    run "mix release"
    inputs ["**/*.ex", "**/*.exs", "mix.exs", "mix.lock"]
    output "release", "_build/prod/rel/myapp"
    after_ ["test"]
  end

  # Deploy only runs on main branch
  # Condition is evaluated at runtime
  task "deploy" do
    run "./deploy.sh"
    when_ "branch == 'main'"
    after_ ["build"]
  end

  # Type-safe conditions
  # These are caught at compile time, not runtime
  alias Sykli.Condition

  task "release" do
    run "./release.sh"
    when_cond Condition.branch("main") |> Condition.or_cond(Condition.tag("v*"))
    after_ ["build"]
  end
end

# First run:  All tasks execute (no cache)
# Second run: Tasks with unchanged inputs are skipped
# Third run:  Only changed files trigger re-execution
