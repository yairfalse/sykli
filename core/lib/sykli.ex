defmodule Sykli do
  @moduledoc """
  SYKLI - CI that understands your stack.

  Direct orchestration: detect SDK file, run it, parse JSON, execute tasks.
  """

  alias Sykli.{Detector, Graph, Executor}

  def run(path \\ ".") do
    with {:ok, sdk_file} <- Detector.find(path),
         {:ok, json} <- Detector.emit(sdk_file),
         {:ok, graph} <- Graph.parse(json),
         {:ok, order} <- Graph.topo_sort(graph) do
      Executor.run(order, graph, workdir: path)
    end
  end
end
