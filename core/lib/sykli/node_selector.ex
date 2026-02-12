defmodule Sykli.NodeSelector do
  @moduledoc """
  Select and try nodes for task execution.

  Strategy: filter by labels, then try nodes until one works.
  Labels are optional - without them, all nodes are tried.

  ## Usage

      # Filter nodes that have required labels
      candidates = NodeSelector.filter_by_labels(task, nodes, capabilities)

      # Try nodes in order until one succeeds
      {:ok, node} = NodeSelector.try_nodes(task, candidates, opts, runner_fn)

      # Combined: filter + try
      {:ok, node} = NodeSelector.select_and_try(task, nodes, caps, opts, runner_fn)

  ## Error Handling

  When no nodes can run the task, returns a rich `PlacementError` with:
  - List of all tried nodes and why they failed
  - Hints for how to fix the problem
  """

  alias __MODULE__.PlacementError

  @type node_ref :: :local | node()
  @type capabilities :: %{node_ref() => %{labels: [String.t()]}}
  @type runner :: (node_ref(), map(), keyword() -> :ok | {:error, term()})

  @doc """
  Filter nodes by task's required labels.

  Returns nodes that have ALL required labels. If task has no requirements,
  returns all nodes unchanged.

  ## Examples

      iex> caps = %{local: %{labels: ["docker"]}, server: %{labels: ["gpu"]}}
      iex> NodeSelector.filter_by_labels(%{requires: ["gpu"]}, [:local, :server], caps)
      [:server]
  """
  @spec filter_by_labels(map(), [node_ref()], capabilities()) :: [node_ref()]
  def filter_by_labels(task, nodes, capabilities) do
    required = Map.get(task, :requires) || []

    if required == [] do
      nodes
    else
      Enum.filter(nodes, fn node ->
        node_labels = get_in(capabilities, [node, :labels]) || []
        Enum.all?(required, &(&1 in node_labels))
      end)
    end
  end

  @doc """
  Try nodes in order until one succeeds.

  The `runner` function is called for each node. It should return `:ok` on
  success or `{:error, reason}` on failure.

  ## Returns

  - `{:ok, node}` - First node that succeeded
  - `{:error, %PlacementError{}}` - All nodes failed (with details)

  ## Examples

      runner = fn node, task, opts ->
        Mesh.dispatch_task(task, node, opts)
      end

      {:ok, :server1} = NodeSelector.try_nodes(task, [:local, :server1], [], runner)
  """
  @spec try_nodes(map(), [node_ref()], keyword(), runner()) ::
          {:ok, node_ref()} | {:error, PlacementError.t()}
  def try_nodes(task, nodes, opts, runner)

  def try_nodes(task, [], _opts, _runner) do
    {:error, PlacementError.no_nodes(task)}
  end

  def try_nodes(task, nodes, opts, runner) do
    do_try_nodes(task, nodes, opts, runner, _failures = [])
  end

  defp do_try_nodes(task, [], _opts, _runner, failures) do
    {:error, PlacementError.all_failed(task, Enum.reverse(failures))}
  end

  defp do_try_nodes(task, [node | rest], opts, runner, failures) do
    case runner.(node, task, opts) do
      :ok ->
        {:ok, node}

      {:ok, output} ->
        {:ok, node, output}

      {:error, reason} ->
        do_try_nodes(task, rest, opts, runner, [{node, reason} | failures])
    end
  end

  @doc """
  Filter by labels, then try nodes.

  Combines `filter_by_labels/3` and `try_nodes/4`.

  ## Returns

  - `{:ok, node}` - First matching node that succeeded
  - `{:error, %PlacementError{no_matching_nodes: true}}` - No nodes have required labels
  - `{:error, %PlacementError{}}` - All matching nodes failed
  """
  @spec select_and_try(map(), [node_ref()], capabilities(), keyword(), runner()) ::
          {:ok, node_ref()} | {:error, PlacementError.t()}
  def select_and_try(task, nodes, capabilities, opts, runner) do
    candidates = filter_by_labels(task, nodes, capabilities)

    if candidates == [] and Map.get(task, :requires, []) != [] do
      {:error, PlacementError.no_matching(task)}
    else
      try_nodes(task, candidates, opts, runner)
    end
  end
end

defmodule Sykli.NodeSelector.PlacementError do
  @moduledoc """
  Rich error for task placement failures.

  Contains details about which nodes were tried, why they failed,
  and hints for how to fix the problem.
  """

  @type t :: %__MODULE__{
          task_name: String.t(),
          failures: [{Sykli.NodeSelector.node_ref(), term()}],
          no_matching_nodes: boolean(),
          required_labels: [String.t()],
          available_nodes: [Sykli.NodeSelector.node_ref()]
        }

  defstruct [
    :task_name,
    failures: [],
    no_matching_nodes: false,
    required_labels: [],
    available_nodes: []
  ]

  @doc "Create error when no nodes were provided"
  def no_nodes(task) do
    %__MODULE__{
      task_name: task_name(task),
      failures: [],
      no_matching_nodes: true
    }
  end

  @doc "Create error when no nodes match required labels"
  def no_matching(task) do
    %__MODULE__{
      task_name: task_name(task),
      failures: [],
      no_matching_nodes: true,
      required_labels: Map.get(task, :requires, [])
    }
  end

  @doc "Create error when all nodes failed"
  def all_failed(task, failures) do
    %__MODULE__{
      task_name: task_name(task),
      failures: failures
    }
  end

  @doc """
  Format the error as a human-readable string.

  Produces output like:

      ✗ build failed: no nodes can run this task

        Nodes tried:
          local     → docker daemon not running
          server1   → docker: permission denied

        Fix options:
          • Start Docker Desktop locally
          • Add a node with docker: SYKLI_LABELS=docker
  """
  @spec format(t()) :: String.t()
  def format(%__MODULE__{} = error) do
    [
      header(error),
      nodes_section(error),
      hints_section(error)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  @doc """
  Generate fix hints based on failure patterns.

  Returns a list of actionable suggestions.
  """
  @spec hints(t()) :: [String.t()]
  def hints(%__MODULE__{} = error) do
    []
    |> add_docker_hints(error)
    |> add_label_hints(error)
    |> add_generic_hints(error)
  end

  # ---------------------------------------------------------------------------
  # PRIVATE - Formatting
  # ---------------------------------------------------------------------------

  defp header(%{
         task_name: name,
         no_matching_nodes: true,
         required_labels: labels,
         available_nodes: nodes
       })
       when labels != [] do
    base =
      "✗ #{name} failed: no nodes match requirements\n\n  Task requires: #{Enum.join(labels, ", ")}"

    if nodes != [] do
      node_list = nodes |> Enum.map(&to_string/1) |> Enum.join(", ")
      base <> "\n  Available nodes: #{node_list}"
    else
      base
    end
  end

  defp header(%{task_name: name}) do
    "✗ #{name} failed: no nodes can run this task"
  end

  defp nodes_section(%{failures: []}) do
    nil
  end

  defp nodes_section(%{failures: failures}) do
    lines =
      failures
      |> Enum.map(fn {node, reason} ->
        "    #{format_node(node)} → #{format_reason(reason)}"
      end)
      |> Enum.join("\n")

    "  Nodes tried:\n#{lines}"
  end

  defp hints_section(error) do
    case hints(error) do
      [] ->
        nil

      hints ->
        lines = Enum.map(hints, &"    • #{&1}") |> Enum.join("\n")
        "  Fix options:\n#{lines}"
    end
  end

  defp format_node(node) when is_atom(node) do
    node |> to_string() |> String.pad_trailing(12)
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason({:exit_code, code}), do: "exited with code #{code}"
  defp format_reason(%{reason: reason}), do: to_string(reason)
  defp format_reason(reason), do: inspect(reason)

  # ---------------------------------------------------------------------------
  # PRIVATE - Hints
  # ---------------------------------------------------------------------------

  defp add_docker_hints(hints, %{failures: failures}) do
    has_docker_error =
      Enum.any?(failures, fn {_node, reason} ->
        reason_str = format_reason(reason)
        String.contains?(reason_str, "docker")
      end)

    if has_docker_error do
      ["Start Docker Desktop or ensure docker daemon is running" | hints]
    else
      hints
    end
  end

  defp add_label_hints(hints, %{no_matching_nodes: true, required_labels: labels})
       when labels != [] do
    label_str = Enum.join(labels, ",")
    ["Add labels to a node: SYKLI_LABELS=#{label_str}" | hints]
  end

  defp add_label_hints(hints, _), do: hints

  defp add_generic_hints(hints, _), do: hints

  defp task_name(%{name: name}), do: name
  defp task_name(_), do: "unknown"
end
