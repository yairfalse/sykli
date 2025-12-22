defmodule Sykli do
  @moduledoc """
  SYKLI - CI that understands your stack.

  Direct orchestration: detect SDK file, run it, parse JSON, execute tasks.
  """

  alias Sykli.{Detector, Graph, Executor, Cache}

  def run(path \\ ".") do
    Cache.init()

    with {:ok, sdk_file} <- Detector.find(path),
         {:ok, json} <- Detector.emit(sdk_file),
         {:ok, graph} <- Graph.parse(json) do
      # Expand matrix tasks into individual tasks
      expanded_graph = Graph.expand_matrix(graph)

      case Graph.topo_sort(expanded_graph) do
        {:ok, order} -> Executor.run(order, expanded_graph, workdir: path)
        error -> error
      end
    else
      {:error, :no_sdk_file} ->
        IO.puts(:stderr, "\e[31m✗ No sykli file found\e[0m")
        IO.puts(:stderr, "  Create one of: sykli.go, sykli.rs, or sykli.exs")
        {:error, :no_sdk_file}

      {:error, {:missing_tool, tool, hint}} ->
        IO.puts(:stderr, "\e[31m✗ '#{tool}' is not installed\e[0m")
        IO.puts(:stderr, "  #{hint}")
        {:error, {:missing_tool, tool}}

      {:error, {:go_failed, output}} ->
        IO.puts(:stderr, "\e[31m✗ Go SDK failed\e[0m")
        IO.puts(:stderr, output)
        {:error, :go_failed}

      {:error, {:rust_failed, output}} ->
        IO.puts(:stderr, "\e[31m✗ Rust SDK failed\e[0m")
        IO.puts(:stderr, output)
        {:error, :rust_failed}

      {:error, {:rust_cargo_failed, output}} ->
        IO.puts(:stderr, "\e[31m✗ Cargo build failed\e[0m")
        IO.puts(:stderr, output)
        {:error, :cargo_failed}

      {:error, {:elixir_failed, output}} ->
        IO.puts(:stderr, "\e[31m✗ Elixir SDK failed\e[0m")
        IO.puts(:stderr, output)
        {:error, :elixir_failed}

      {:error, {:json_parse_error, error}} ->
        IO.puts(:stderr, "\e[31m✗ Failed to parse task graph\e[0m")
        IO.puts(:stderr, "  #{inspect(error)}")
        {:error, :json_parse_error}

      error ->
        IO.puts(:stderr, "\e[31m✗ Error: #{inspect(error)}\e[0m")
        error
    end
  end
end
