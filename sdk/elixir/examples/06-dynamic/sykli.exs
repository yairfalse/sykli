# Example 06: Dynamic Pipelines
#
# This example demonstrates:
# - Using Elixir code for dynamic task generation
# - Loops and comprehensions for repeated patterns
# - Conditionals for environment-specific tasks
# - matrix_tasks for testing across configurations
# - Service containers and secrets
#
# Since it's real Elixir, you have full language power!
#
# Run with: elixir sykli.exs --emit | sykli run -

Mix.install([{:sykli, "~> 0.2"}])

use Sykli

pipeline do
  # === DYNAMIC: LOOP OVER APPS ===
  # Test each app in a monorepo
  apps = ["api", "web", "worker"]

  for app <- apps do
    task "test-#{app}" do
      run "mix test apps/#{app}"
    end
  end

  # === MATRIX BUILDS ===
  # Test across Elixir versions
  versions = matrix_tasks("elixir-versions", ["1.14", "1.15", "1.16"], fn version ->
    task_ref("test-elixir-#{version}")
    |> run_cmd("mix test")
    |> with_container("elixir:#{version}")
  end)

  # === SERVICE CONTAINERS ===
  # Integration tests with database and cache
  task "integration" do
    container "elixir:1.16"
    mount_cwd()
    service "postgres:15", "db"
    service "redis:7", "cache"
    env "DATABASE_URL", "postgres://postgres:postgres@db:5432/test"
    env "REDIS_URL", "redis://cache:6379"
    run "mix test --only integration"
    timeout 300
    after_group versions
  end

  # === RETRY & TIMEOUT ===
  task "e2e" do
    container "playwright/playwright:latest"
    mount_cwd()
    run "npm run e2e"
    retry 3
    timeout 600
    after_ ["integration"]
  end

  # === SECRETS ===
  task "publish" do
    secret "HEX_API_KEY"
    run "mix hex.publish"
    when_ "tag != ''"
    after_ ["e2e"]
  end

  # === CONDITIONAL DEPLOYMENT ===
  # Deploy depends on all app tests
  task "deploy" do
    run "./deploy.sh"
    after_ Enum.map(apps, &"test-#{&1}")
    when_ "branch == 'main'"
  end

  # Deploy to prod only on tags
  task "deploy-prod" do
    run "./deploy.sh --prod"
    secret "DEPLOY_TOKEN"
    after_ ["e2e"]
    when_ "tag matches 'v*'"
  end
end

# Generated tasks:
#
# test-api         ─┐
# test-web         ─┼─> deploy (on main)
# test-worker      ─┘
#
# test-elixir-1.14 ─┐
# test-elixir-1.15 ─┼─> integration ─> e2e ─> publish (on tag)
# test-elixir-1.16 ─┘                       ─> deploy-prod (on v* tag)
