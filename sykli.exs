# Sykli CI for Sykli itself - dogfooding!
#
# Run locally:  sykli
# Run in CI:    sykli (via GitHub Actions)

Mix.install([{:sykli_sdk, path: "sdk/elixir"}])

use Sykli

pipeline do
  # === CORE TESTS ===
  task "core:deps" do
    run "mix deps.get"
    workdir "core"
  end

  task "core:test" do
    run "mix test"
    workdir "core"
    after_ ["core:deps"]
  end

  task "core:build" do
    run "mix escript.build"
    workdir "core"
    after_ ["core:test"]
  end

  # === SDK TESTS (parallel) ===
  task "sdk:go" do
    run "go test ./..."
    workdir "sdk/go"
  end

  task "sdk:rust" do
    run "cargo test"
    workdir "sdk/rust"
  end

  task "sdk:elixir:deps" do
    run "mix deps.get"
    workdir "sdk/elixir"
  end

  task "sdk:elixir" do
    run "mix test"
    workdir "sdk/elixir"
    after_ ["sdk:elixir:deps"]
  end

  # === INTEGRATION (after everything) ===
  task "integration" do
    run "./sykli ../examples/go-project"
    workdir "core"
    after_ ["core:build", "sdk:go"]
  end
end
