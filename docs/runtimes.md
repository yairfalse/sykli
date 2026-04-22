# Sykli Runtimes

Sykli separates **targets** (WHERE a task runs) from **runtimes** (HOW a command executes). The runtime is the module that turns "run this command" into a real process.

## Supported runtimes

| Runtime | Module | When to use |
|---|---|---|
| **Shell** | `Sykli.Runtime.Shell` | No container isolation needed; dev/debug; containerless tasks |
| **Docker** | `Sykli.Runtime.Docker` | Production container execution |
| **Podman** | `Sykli.Runtime.Podman` | Rootless container execution; Docker-less hosts |
| **Fake** | `Sykli.Runtime.Fake` | Unit tests; mesh simulation — deterministic, no external binaries |

All four implement `Sykli.Runtime.Behaviour`.

## How the runtime is picked

`Sykli.Target.Local` composes two runtimes: a **container runtime** for tasks with a container image, and a **containerless runtime** for tasks without one. Both flow through `Sykli.Runtime.Resolver`.

### Container runtime priority (first match wins)

1. `--runtime <name>` / `-r <name>` CLI flag
2. `opts[:runtime]` — when Sykli is called as a library
3. `config :sykli, :default_runtime` — from `core/config/<env>.exs`
4. `SYKLI_RUNTIME` env var (`docker` / `podman` / `shell` / `fake`, or `Elixir.Fully.Qualified.Module`)
5. Auto-detect: first of Docker, Podman whose `available?/0` succeeds
6. Fall back to `Sykli.Runtime.Shell` (a warning logs once per VM boot)

### Containerless runtime priority (first match wins)

1. `opts[:containerless_runtime]`
2. `Application.get_env(:sykli, :containerless_runtime)`
3. Default: `Sykli.Runtime.Shell`

Configured per-environment:

- `:test` env — `Sykli.Runtime.Fake` is the default (no Docker required for unit tests)
- `:dev` / `:prod` — `nil` triggers auto-detect

## Selecting at the command line

```bash
# Use Podman explicitly
SYKLI_RUNTIME=podman sykli run build

# Same via CLI flag
sykli --runtime podman run build

# Short form
sykli -r podman run build
```

## Inspecting the current selection

```bash
mix sykli.runtime.info
```

prints the resolved container and containerless runtimes plus availability of each known runtime.

## Adding a new runtime

1. Create `core/lib/sykli/runtime/<name>.ex` implementing `@behaviour Sykli.Runtime.Behaviour`:
   - Required: `name/0`, `available?/0`, `run/4`
   - Optional: `start_service/4`, `stop_service/1`, `create_network/1`, `remove_network/1`
2. If you want shorthand `SYKLI_RUNTIME=<name>` to resolve to it, add an entry to `@shorthand` in `Sykli.Runtime.Resolver`.
3. Write tests mirroring `core/test/sykli/runtime/podman_test.exs`. Tag them `:<name>` (e.g. `:containerd`) and add the tag to `core/test/test_helper.exs`'s default exclude list.
4. Add the `test.<name>` alias in `mix.exs` and update `cli/0` so `preferred_envs` includes it.
5. No extra guard wiring is needed for the existing regression guards: they auto-discover runtime implementations from `core/lib/sykli/runtime/*.ex`.

These are the required repo updates for wiring in a new runtime.
