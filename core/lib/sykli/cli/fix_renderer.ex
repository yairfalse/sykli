defmodule Sykli.CLI.FixRenderer do
  @moduledoc "Pure renderer for `sykli fix` terminal output."

  alias Sykli.CLI.Theme

  @width 64

  def render(result, opts \\ [])

  def render(%{status: :nothing_to_fix}, opts) do
    [color(Theme.glyph(:pass), :accent, opts), "  Nothing to fix. Last run passed."]
  end

  def render(%{status: :failure_found} = result, opts) do
    [
      render_header(result, opts),
      "\n\n",
      Enum.map(result.tasks, &render_task(&1, opts)),
      render_diff(result.diff_since_last_good, opts)
    ]
  end

  defp render_header(result, opts) do
    summary = result.summary || %{}
    failed = summary["failed_count"] || length(result.tasks || [])
    total = summary["total_count"] || failed
    ref = summary["git_ref"]
    branch = summary["git_branch"]

    git =
      cond do
        ref && branch -> " · #{String.slice(ref, 0, 7)} · #{branch}"
        ref -> " · #{String.slice(ref, 0, 7)}"
        true -> ""
      end

    [
      color(Theme.glyph(:fail), :error, opts),
      "  ",
      "#{failed} of #{total} tasks failed",
      color(git, :dim, opts)
    ]
  end

  defp render_task(task, opts) do
    [
      color(Theme.glyph(:fail), :error, opts),
      "  ",
      task["name"],
      "  ",
      color(
        String.duplicate("─", max(8, @width - String.length(task["name"] || "") - 6)),
        :error,
        opts
      ),
      "\n\n",
      render_command(task),
      render_locations(task["locations"] || [], opts),
      render_causes(task["possible_causes"] || [], opts),
      render_fix(task["suggested_fix"], opts),
      render_history(task["history"], opts),
      "\n"
    ]
  end

  defp render_command(task) do
    case {task["command"], task["exit_code"]} do
      {nil, nil} ->
        []

      {command, nil} ->
        ["    $ ", command, "\n\n"]

      {command, code} ->
        ["    $ ", command || "", "\n", "    exit code ", to_string(code), "\n\n"]
    end
  end

  defp render_locations([], _opts), do: []

  defp render_locations(locations, opts) do
    Enum.map(locations, fn loc ->
      [
        color("    " <> location_label(loc), :dim, opts),
        "\n",
        render_location_message(loc, opts),
        render_source(loc["source_lines"], opts),
        "\n"
      ]
    end)
  end

  defp render_location_message(%{"message" => message}, opts) when is_binary(message),
    do: [color("    " <> message, :error, opts), "\n"]

  defp render_location_message(_loc, _opts), do: []

  defp render_source(nil, _opts), do: []

  defp render_source(lines, opts) do
    Enum.map(lines, fn line ->
      style = if String.starts_with?(line, ">>"), do: :error, else: :dim
      [color("    " <> line, style, opts), "\n"]
    end)
  end

  defp render_causes([], _opts), do: []

  defp render_causes(causes, opts) do
    Enum.map(causes, fn cause ->
      ["    ", color("because", :warning, opts), "  ", cause, "\n"]
    end) ++ ["\n"]
  end

  defp render_fix(nil, _opts), do: []
  defp render_fix(fix, opts), do: ["    ", color("fix", :accent, opts), "      ", fix, "\n\n"]

  defp render_history(nil, _opts), do: []

  defp render_history(history, opts) do
    parts =
      []
      |> maybe_append(history["pass_rate"], fn rate -> "#{round(rate * 100)}% pass rate" end)
      |> maybe_append(history["streak"], fn streak -> "streak: #{streak}" end)
      |> maybe_append(history["flaky"], fn _ -> "flaky" end)

    if parts == [], do: [], else: [color("    " <> Enum.join(parts, " · "), :dim, opts), "\n"]
  end

  defp render_diff(nil, _opts), do: []

  defp render_diff(diff, opts) do
    ref = diff["ref"] || "last pass"
    stat = diff["stat"]

    [
      color("Changes since #{ref}", :dim, opts),
      "\n",
      if(stat && stat != "", do: indent(stat), else: [])
    ]
  end

  defp location_label(%{"file" => file, "line" => line})
       when is_binary(file) and not is_nil(line),
       do: "#{file}:#{line}"

  defp location_label(%{"file" => file}) when is_binary(file), do: file
  defp location_label(_), do: "location unknown"

  defp indent(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.map_join("\n", &"    #{&1}")
  end

  defp maybe_append(list, nil, _fun), do: list
  defp maybe_append(list, false, _fun), do: list
  defp maybe_append(list, value, fun), do: list ++ [fun.(value)]

  defp color(text, style, opts) do
    if Keyword.get(opts, :ansi?, false), do: [ansi(style), text, Theme.reset()], else: text
  end

  defp ansi(:accent), do: Theme.accent()
  defp ansi(:error), do: Theme.error()
  defp ansi(:warning), do: Theme.warning()
  defp ansi(:dim), do: Theme.dim()
end
