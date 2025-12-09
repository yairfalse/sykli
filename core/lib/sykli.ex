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
    end
  end
end
