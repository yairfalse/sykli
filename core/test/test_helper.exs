# Default exclusions — both require a container runtime on the host:
#   :integration — cross-system integration tests
#   :docker      — tests that exercise real Docker behaviour specifically
# Run the respective tiers via:
#   mix test.integration
#   mix test.docker
# Or include ad-hoc:
#   mix test --include docker
#   mix test --include integration
ExUnit.start(exclude: [:integration, :docker])
