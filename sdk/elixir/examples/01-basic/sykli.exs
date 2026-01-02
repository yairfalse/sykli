# Example 01: Basic Pipeline
#
# This example demonstrates:
# - Creating tasks with `run`
# - Defining dependencies with `after_`
# - Parallel execution of independent tasks
#
# Run with: elixir sykli.exs --emit | sykli run -

Mix.install([{:sykli, "~> 0.2"}])

use Sykli

pipeline do
  # Independent tasks run in parallel
  task "lint" do
    run "mix credo --strict"
  end

  task "test" do
    run "mix test"
  end

  # Build depends on both lint and test
  # It won't start until both complete successfully
  task "build" do
    run "mix release"
    after_ ["lint", "test"]
  end

  # Deploy depends on build
  # Only runs after build completes
  task "deploy" do
    run "echo 'Deploying...'"
    after_ ["build"]
  end
end

# Expected execution order:
#
# Level 0 (parallel):  lint, test
# Level 1:             build
# Level 2:             deploy
#
# Total: 4 tasks in 3 levels
