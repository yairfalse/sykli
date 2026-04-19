defmodule CredoSykli.Check.NoWallClock do
  @moduledoc """
  Forbids wall-clock and unscoped global RNG calls in simulator-facing production code.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Simulator-facing production code must not read wall-clock time or use global RNG state.
      Route time through transport APIs such as `now_ms/0` and randomness through explicit seeded state.
      """,
      params: [
        severity: "Severity assigned to each reported issue."
      ]
    ],
    param_defaults: [
      severity: :warning
    ]

  alias Credo.Check.Params
  alias Credo.IssueMeta
  alias Credo.SourceFile

  @spec run(SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(%SourceFile{} = source_file, params \\ []) do
    if relevant_file?(source_file.filename) do
      issue_meta = IssueMeta.for(source_file, params)

      source_file
      |> Credo.Code.prewalk(&traverse(&1, &2, issue_meta), [])
      |> Enum.reverse()
    else
      []
    end
  end

  defp traverse(ast, issues, issue_meta) do
    case offense(ast) do
      {:ok, meta, trigger} ->
        {ast, [issue_for(issue_meta, meta[:line], trigger) | issues]}

      :error ->
        {ast, issues}
    end
  end

  defp offense({{:., meta, [{:__aliases__, _, [:System]}, :monotonic_time]}, _, _args}) do
    {:ok, meta, "System.monotonic_time"}
  end

  defp offense({{:., meta, [{:__aliases__, _, [:System]}, :os_time]}, _, _args}) do
    {:ok, meta, "System.os_time"}
  end

  defp offense({{:., meta, [{:__aliases__, _, [:DateTime]}, :utc_now]}, _, _args}) do
    {:ok, meta, "DateTime.utc_now"}
  end

  defp offense({{:., meta, [{:__aliases__, _, [:NaiveDateTime]}, :utc_now]}, _, _args}) do
    {:ok, meta, "NaiveDateTime.utc_now"}
  end

  defp offense({{:., meta, [:os, :system_time]}, _, _args}) do
    {:ok, meta, ":os.system_time"}
  end

  defp offense({{:., meta, [:erlang, :now]}, _, _args}) do
    {:ok, meta, ":erlang.now"}
  end

  defp offense({{:., meta, [:rand, :uniform]}, _, [_arg]}) do
    {:ok, meta, ":rand.uniform"}
  end

  defp offense(_ast), do: :error

  defp issue_for(issue_meta, line_no, trigger) do
    format_issue(
      issue_meta,
      message:
        "Use transport-scoped virtual time and explicit seeded RNG instead of wall-clock or global RNG.",
      line_no: line_no,
      trigger: trigger,
      severity: Params.get(IssueMeta.params(issue_meta), :severity, __MODULE__)
    )
  end

  defp relevant_file?(filename) do
    normalized = Path.relative_to_cwd(filename)

    contains_lib_sykli?(normalized) and
      not String.ends_with?(normalized, "lib/sykli/mesh/transport/erlang.ex") and
      not String.contains?(normalized, "/lib/credo_sykli/")
  end

  defp contains_lib_sykli?(filename) do
    String.starts_with?(filename, "lib/sykli/") or String.contains?(filename, "/lib/sykli/")
  end
end
