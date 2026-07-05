defmodule Sykli.Gui.Assets do
  @moduledoc """
  Workbench static assets, embedded at compile time.

  The dev binary is an escript, and files under `priv/` are not readable
  as filesystem paths from inside an escript archive — `Plug.Static`
  cannot serve them. Embedding the (small, hand-written) SPA as module
  binaries makes `sykli gui` work identically from `mix`, the escript,
  and Burrito releases.
  """

  @assets_dir Path.join(:code.priv_dir(:sykli) |> to_string(), "gui")

  @manifest [
    {"index.html", "text/html"},
    {"app.css", "text/css"},
    {"app.js", "application/javascript"},
    {"fs-mark.png", "image/png"}
  ]

  for {name, _content_type} <- @manifest do
    path = Path.join(@assets_dir, name)

    if File.exists?(path) do
      @external_resource path
    end
  end

  @embedded (for {name, content_type} <- @manifest,
                 path = Path.join(@assets_dir, name),
                 File.exists?(path),
                 into: %{} do
               {name, {content_type, File.read!(path)}}
             end)

  @doc """
  Fetches an embedded asset: `{:ok, content_type, body}` or `:error`.
  """
  def fetch(name) do
    case Map.fetch(@embedded, name) do
      {:ok, {content_type, body}} -> {:ok, content_type, body}
      :error -> :error
    end
  end

  @doc "Names of assets that were present at compile time."
  def available, do: Map.keys(@embedded)
end
