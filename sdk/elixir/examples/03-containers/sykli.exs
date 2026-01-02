# Example 03: Container Execution
#
# This example demonstrates:
# - `container` for isolated execution
# - `dir` and `cache` resources
# - `mount` and `mount_cache` for volumes
# - `workdir` for working directory
# - `env` for environment variables
#
# Run with: elixir sykli.exs --emit | sykli run -

Mix.install([{:sykli, "~> 0.2"}])

use Sykli

pipeline do
  # === RESOURCES ===

  # Source directory - mounted into containers
  src = dir(".")

  # Named caches - persist across runs
  deps_cache = cache("mix-deps")
  build_cache = cache("mix-build")

  # === TASKS ===

  # Lint in container with source mounted
  task "lint" do
    container "elixir:1.16"
    mount src, "/app"
    mount_cache deps_cache, "/app/deps"
    workdir "/app"
    run "mix credo --strict"
  end

  # Test with multiple caches
  task "test" do
    container "elixir:1.16"
    mount src, "/app"
    mount_cache deps_cache, "/app/deps"
    mount_cache build_cache, "/app/_build"
    workdir "/app"
    env "MIX_ENV", "test"
    run "mix test"
  end

  # Build with environment variable
  task "build" do
    container "elixir:1.16"
    mount src, "/app"
    mount_cache deps_cache, "/app/deps"
    mount_cache build_cache, "/app/_build"
    workdir "/app"
    env "MIX_ENV", "prod"
    run "mix release"
    output "release", "_build/prod/rel/myapp"
    after_ ["lint", "test"]
  end

  # === CONVENIENCE METHODS ===

  # mount_cwd() is shorthand for mounting . to /work
  task "check-format" do
    container "elixir:1.16"
    mount_cwd()  # Mounts current dir to /work, sets workdir
    run "mix format --check-formatted"
  end
end

# Key concepts:
# - dir(".")      - Represents a host directory
# - cache("name") - Named persistent cache volume
# - mount(d, p)   - Mount directory at container path
# - mount_cache() - Mount cache for faster builds
# - workdir()     - Set container working directory
