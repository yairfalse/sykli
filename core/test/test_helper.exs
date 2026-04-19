# Default exclusions — all require a container runtime on the host:
#   :integration — cross-system integration tests
#   :docker      — tests that exercise real Docker behaviour
#   :podman      — tests that exercise real Podman behaviour
# Run the respective tiers via:
#   mix test.integration
#   mix test.docker
#   mix test.podman
# Or include ad-hoc:
#   mix test --include docker
#   mix test --include podman
#   mix test --include integration
ExUnit.start(exclude: [:integration, :docker, :podman])
