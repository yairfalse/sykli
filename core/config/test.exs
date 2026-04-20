import Config

# The Fake runtime is deterministic and requires no external binaries.
# Tests that need a real container runtime tag @moduletag :docker
# (or :podman) and run via `mix test.docker` / `mix test.podman`.
config :sykli, default_runtime: Sykli.Runtime.Fake
