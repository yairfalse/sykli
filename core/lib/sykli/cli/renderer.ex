defmodule Sykli.CLI.Renderer do
  @moduledoc "Pure renderer for `sykli run` terminal output."

  alias Sykli.CLI.Theme
  alias Sykli.Executor.TaskResult

  @width 64
  @name_width 12
  @output_lines 10

  def render_run(pipeline_path, target, version, results, duration_ms, opts \\ []) do
    [
      render_header(pipeline_path, target, version, opts),
      "\n\n",
      Enum.map(results, &render_task_row(&1, opts)),
      "\n",
      render_summary(%{results: results, duration_ms: duration_ms}, opts),
      failure_blocks(results, opts)
    ]
  end

  def render_header(pipeline_path, target, version, opts \\ []) do
    left = "sykli · #{Path.basename(to_string(pipeline_path))}"
    right = "#{target} · #{version}"

    line =
      left <>
        String.duplicate(" ", max(1, @width - visible_length(left) - visible_length(right))) <>
        right

    color(line, :dim, opts)
  end

  def render_task_row(%TaskResult{} = result, opts \\ []) do
    command = result_command(result)

    left = [
      "  ",
      glyph_for(result.status, opts),
      "  ",
      pad(result.name, @name_width),
      "  ",
      command
    ]

    right = task_suffix(result)

    [align(left, right), "\n"]
  end

  def render_running_row(
        %{name: name, command: command},
        frame \\ Theme.glyph(:running),
        opts \\ []
      ) do
    left = ["  ", color(frame, :accent, opts), "  ", pad(name, @name_width), "  ", command || ""]
    [left, "\n"]
  end

  def render_summary(%{results: results, duration_ms: duration_ms}, _opts \\ []) do
    left = ["  ", Theme.glyph(:blocked), "  ", summary_text(results)]
    [align(left, format_duration(duration_ms)), "\n"]
  end

  def separator, do: String.duplicate("─", 45)

  def render_separator, do: separator()

  def render_failure_block(%TaskResult{} = result, opts \\ []) do
    [
      "\n  ",
      color(Theme.glyph(:fail), :error, opts),
      "  ",
      result.name,
      "  ",
      color(separator(), :error, opts),
      "\n\n",
      output_excerpt(failure_output(result)),
      "\n",
      render_fix_hint(opts),
      "\n"
    ]
  end

  def render_fix_hint(opts \\ []) do
    color("      Run  sykli fix  for AI-readable analysis.", :dim, opts)
  end

  def format_duration(ms) when is_integer(ms) and ms < 1000, do: "#{ms}ms"
  def format_duration(ms) when is_integer(ms) and ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"
  def format_duration(ms) when is_integer(ms), do: "#{Float.round(ms / 60_000, 1)}m"
  def format_duration(_), do: ""

  defp failure_blocks(results, opts) do
    results
    |> Enum.filter(&failed?/1)
    |> Enum.map(&render_failure_block(&1, opts))
  end

  defp glyph_for(:passed, opts), do: color(Theme.glyph(:pass), :accent, opts)
  defp glyph_for(:cached, _opts), do: Theme.glyph(:cache)
  defp glyph_for(:failed, opts), do: color(Theme.glyph(:fail), :error, opts)
  defp glyph_for(:errored, opts), do: color(Theme.glyph(:fail), :error, opts)
  defp glyph_for(:blocked, _opts), do: Theme.glyph(:blocked)
  defp glyph_for(:skipped, _opts), do: Theme.glyph(:blocked)

  defp task_suffix(%TaskResult{status: :cached}), do: "(cache)"
  defp task_suffix(%TaskResult{status: :blocked}), do: "skipped (blocked)"
  defp task_suffix(%TaskResult{status: :skipped}), do: "skipped"
  defp task_suffix(%TaskResult{duration_ms: ms}), do: format_duration(ms)

  defp summary_text(results) do
    results
    |> Enum.map(&summary_status/1)
    |> Enum.frequencies()
    |> Enum.filter(fn {_status, count} -> count > 0 end)
    |> Enum.sort_by(fn {status, _count} -> summary_order(status) end)
    |> Enum.map(fn {status, count} -> "#{count} #{plural(status, count)}" end)
    |> Enum.join(" · ")
  end

  defp summary_status(%TaskResult{status: status}) when status in [:failed, :errored], do: :failed
  defp summary_status(%TaskResult{status: :passed}), do: :passed
  defp summary_status(%TaskResult{status: :cached}), do: :cached
  defp summary_status(%TaskResult{status: :blocked}), do: :blocked
  defp summary_status(%TaskResult{status: :skipped}), do: :skipped

  defp summary_order(:failed), do: 0
  defp summary_order(:passed), do: 1
  defp summary_order(:cached), do: 2
  defp summary_order(:blocked), do: 3
  defp summary_order(:skipped), do: 4

  defp plural(:failed, 1), do: "failed"
  defp plural(:failed, _), do: "failed"
  defp plural(:passed, 1), do: "passed"
  defp plural(:passed, _), do: "passed"
  defp plural(:cached, 1), do: "cached"
  defp plural(:cached, _), do: "cached"
  defp plural(:blocked, 1), do: "blocked"
  defp plural(:blocked, _), do: "blocked"
  defp plural(:skipped, 1), do: "skipped"
  defp plural(:skipped, _), do: "skipped"

  defp result_command(%TaskResult{command: command}) when is_binary(command), do: command
  defp result_command(_), do: ""

  defp output_excerpt(nil), do: ""
  defp output_excerpt(""), do: ""

  defp output_excerpt(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.take(-@output_lines)
    |> Enum.map_join("\n", &"      #{&1}")
  end

  defp align(left, right) do
    left_text = IO.iodata_to_binary(left)
    right_text = to_string(right || "")
    spaces = max(1, @width - visible_length(left_text) - visible_length(right_text))
    [left, String.duplicate(" ", spaces), right_text]
  end

  defp pad(value, width) do
    value = to_string(value || "")
    value <> String.duplicate(" ", max(0, width - visible_length(value)))
  end

  defp failed?(%TaskResult{status: status}), do: status in [:failed, :errored]

  defp failure_output(%TaskResult{output: output}) when is_binary(output) and output != "",
    do: output

  defp failure_output(%TaskResult{error: %Sykli.Error{} = error}) do
    [error.message | error.hints || []]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp failure_output(%TaskResult{error: error}) when not is_nil(error), do: inspect(error)
  defp failure_output(_result), do: nil

  defp color(text, style, opts) do
    if Keyword.get(opts, :ansi?, false) do
      [ansi(style), text, Theme.reset()]
    else
      text
    end
  end

  defp ansi(:accent), do: Theme.accent()
  defp ansi(:error), do: Theme.error()
  defp ansi(:warning), do: Theme.warning()
  defp ansi(:dim), do: Theme.dim()

  defp visible_length(value) do
    value
    |> IO.iodata_to_binary()
    |> strip_ansi()
    |> String.length()
  end

  defp strip_ansi(value), do: Regex.replace(~r/\e\[[0-9;]*m/, value, "")
end
