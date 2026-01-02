# Example 05: Composition
#
# This example demonstrates:
# - `parallel` for concurrent task groups
# - `chain` for sequential pipelines
# - `input_from` for artifact passing
# - `after_group` for depending on task groups
#
# These combinators make complex pipelines readable.
#
# Run with: elixir sykli.exs --emit | sykli run -

Mix.install([{:sykli, "~> 0.2"}])

use Sykli

pipeline do
  # === PARALLEL GROUP ===
  # All checks run concurrently
  checks = parallel("checks", [
    task_ref("lint") |> run_cmd("mix credo --strict"),
    task_ref("fmt") |> run_cmd("mix format --check-formatted"),
    task_ref("test") |> run_cmd("mix test"),
    task_ref("dialyzer") |> run_cmd("mix dialyzer")
  ])

  # === BUILD ===
  # Depends on all checks passing
  task "build" do
    run "mix release"
    env "MIX_ENV", "prod"
    output "release", "_build/prod/rel/myapp"
    after_group checks
  end

  # === ARTIFACT PASSING ===
  # input_from automatically:
  # 1. Adds dependency on "build"
  # 2. Makes the artifact available at "./release"
  task "package" do
    container "docker:24"
    mount_cwd()
    input_from "build", "release", "./release"
    run "docker build -t myapp:latest ."
  end

  # === CHAIN ===
  # Alternative way to express sequential dependencies
  integration = task_ref("integration") |> run_cmd("mix test --only integration")
  e2e = task_ref("e2e") |> run_cmd("./scripts/e2e.sh")
  deploy = task_ref("deploy") |> run_cmd("./scripts/deploy.sh")

  # Make integration depend on build
  integration = with_deps(integration, ["build"])

  # Chain creates: integration -> e2e -> deploy
  chain([integration, e2e, deploy])
end

# Execution flow:
#
# [lint]     ─┐
# [fmt]      ─┼─> [build] ─> [package]
# [test]     ─┤
# [dialyzer] ─┘
#              └──────────> [integration] ─> [e2e] ─> [deploy]
