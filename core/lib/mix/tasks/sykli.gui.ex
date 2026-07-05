defmodule Mix.Tasks.Sykli.Gui do
  @shortdoc "Open the local Sykli Workbench (repo control room)"

  @moduledoc """
  Boots the local Workbench web server for the current repo.

      mix sykli.gui [--port N] [--no-open]

  Development convenience — the shipped surface is `sykli gui` on the
  built binary. Local-first: binds 127.0.0.1 only.
  """

  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    Sykli.CLI.Gui.main(args)
  end
end
