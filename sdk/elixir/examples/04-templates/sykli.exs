# Example 04: Templates
#
# This example demonstrates:
# - `template` for reusable configurations
# - `from` to inherit template settings
# - Override template settings per-task
#
# Templates eliminate repetition. Define container, mounts,
# and environment once, reuse across many tasks.
#
# Run with: elixir sykli.exs --emit | sykli run -

Mix.install([{:sykli, "~> 0.2"}])

use Sykli

pipeline do
  # === RESOURCES ===
  src = dir(".")
  deps_cache = cache("mix-deps")
  build_cache = cache("mix-build")
  npm_cache = cache("npm-cache")

  # === TEMPLATES ===

  # Elixir template - common config for all Elixir tasks
  elixir = template("elixir")
    |> template_container("elixir:1.16")
    |> template_mount("src:.", "/app")
    |> template_mount_cache("mix-deps", "/app/deps")
    |> template_mount_cache("mix-build", "/app/_build")
    |> template_workdir("/app")

  # Node template - for JS tooling
  node = template("node")
    |> template_container("node:20-slim")
    |> template_mount("src:.", "/app")
    |> template_mount_cache("npm-cache", "/root/.npm")
    |> template_workdir("/app")

  # === TASKS ===

  # All Elixir tasks inherit from the elixir template
  # Only task-specific config needed now!
  task "lint" do
    from elixir
    run "mix credo --strict"
  end

  task "test" do
    from elixir
    env "MIX_ENV", "test"  # Adds to template env
    run "mix test"
  end

  # Override template settings when needed
  task "build" do
    from elixir
    env "MIX_ENV", "prod"
    run "mix release"
    output "release", "_build/prod/rel/myapp"
    after_ ["lint", "test"]
  end

  # Different template for JS tasks
  task "docs" do
    from node
    run "npm run build:docs"
  end
end

# Without templates (repetitive):
#   task "lint" do
#     container "elixir:1.16"
#     mount src, "/app"
#     workdir "/app"
#     ...
#   end
#   task "test" do
#     container "elixir:1.16"
#     mount src, "/app"
#     workdir "/app"
#     ...
#   end
#
# With templates (DRY):
#   elixir = template("elixir") |> template_container("elixir:1.16") |> ...
#   task "lint" do from elixir; run "mix credo"; end
#   task "test" do from elixir; run "mix test"; end
