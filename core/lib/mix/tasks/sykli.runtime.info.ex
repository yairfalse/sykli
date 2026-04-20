defmodule Mix.Tasks.Sykli.Runtime.Info do
  @moduledoc """
  Prints the currently-resolved Sykli runtime(s) and availability of each
  known runtime.

  Useful for debugging when an environment picks an unexpected runtime.

      mix sykli.runtime.info

  Output:

      Container runtime:     Sykli.Runtime.Fake
      Containerless runtime: Sykli.Runtime.Shell

      Available runtimes:
        Sykli.Runtime.Docker  (available)
        Sykli.Runtime.Podman  (not available)
        Sykli.Runtime.Shell   (available)
        Sykli.Runtime.Fake    (available)
  """

  use Mix.Task

  @shortdoc "Prints the currently-resolved Sykli runtime"

  @known_runtimes [
    Sykli.Runtime.Docker,
    Sykli.Runtime.Podman,
    Sykli.Runtime.Shell,
    Sykli.Runtime.Fake
  ]

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    current = Sykli.Runtime.Resolver.resolve([])
    containerless = Sykli.Runtime.Resolver.resolve_containerless([])

    Mix.shell().info("Container runtime:     #{inspect(current)}")
    Mix.shell().info("Containerless runtime: #{inspect(containerless)}")
    Mix.shell().info("")
    Mix.shell().info("Available runtimes:")

    for module <- @known_runtimes, Code.ensure_loaded?(module) do
      status =
        case module.available?() do
          {:ok, _} -> "available"
          {:error, _} -> "not available"
        end

      Mix.shell().info("  #{inspect(module)}  (#{status})")
    end

    :ok
  end
end
