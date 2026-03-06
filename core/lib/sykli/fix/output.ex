defmodule Sykli.Fix.Output do
  @moduledoc """
  Terminal formatting for `sykli fix` output.

  Uses box-drawing characters matching `Sykli.Error.Formatter` style.
  """

  @box_width 60

  @doc """
  Format a fix analysis result for terminal display.
  """
  def format(%{status: :nothing_to_fix}) do
    "#{IO.ANSI.green()}Nothing to fix — last run passed.#{IO.ANSI.reset()}"
  end

  def format(%{status: :failure_found} = result) do
    parts =
      [format_header(result.summary)] ++
        Enum.map(result.tasks, &format_task_box/1) ++
        diff_section(result.diff_since_last_good)

    Enum.join(parts, "\n\n")
  end

  defp diff_section(nil), do: []
  defp diff_section(diff), do: [format_diff(diff)]

  defp format_header(summary) do
    failed = summary["failed_count"]
    total = summary["total_count"]
    ref = summary["git_ref"]
    branch = summary["git_branch"]

    git_info =
      if ref,
        do: " #{IO.ANSI.faint()}#{ref} (#{branch || "detached"})#{IO.ANSI.reset()}",
        else: ""

    "#{IO.ANSI.red()}#{failed} of #{total} tasks failed#{IO.ANSI.reset()}#{git_info}"
  end

  defp format_task_box(task) do
    colors = build_colors()

    header_text = "fix: #{task["name"]}"
    padding_len = max(0, @box_width - String.length(header_text) - 4)
    padding = String.duplicate("─", padding_len)

    header =
      "#{colors.faint}╭─#{colors.reset} #{colors.yellow}#{header_text}#{colors.reset} #{colors.faint}#{padding}╮#{colors.reset}"

    footer = "#{colors.faint}╰#{String.duplicate("─", @box_width)}╯#{colors.reset}"

    lines =
      [header, box_line("", colors)] ++
        command_lines(task, colors) ++
        [box_line("", colors)] ++
        location_lines(task["locations"] || [], colors) ++
        cause_lines(task["possible_causes"] || [], colors) ++
        fix_line(task["suggested_fix"], colors) ++
        history_lines(task["history"], colors) ++
        regression_line(task["regression"], colors) ++
        [box_line("", colors), footer]

    Enum.join(lines, "\n")
  end

  defp command_lines(task, colors) do
    cmd =
      if task["command"],
        do: [box_line("  #{colors.faint}$#{colors.reset} #{task["command"]}", colors)],
        else: []

    exit =
      if task["exit_code"],
        do: [box_line("  exit code #{task["exit_code"]}", colors)],
        else: []

    cmd ++ exit
  end

  defp location_lines(locations, colors) do
    Enum.flat_map(locations, &format_location(&1, colors))
  end

  defp cause_lines([], _colors), do: []

  defp cause_lines(causes, colors) do
    Enum.map(causes, fn cause ->
      box_line("  #{colors.yellow}cause#{colors.reset}: #{cause}", colors)
    end)
  end

  defp fix_line(nil, _colors), do: []

  defp fix_line(fix, colors) do
    [box_line("  #{colors.green}fix#{colors.reset}:   #{fix}", colors)]
  end

  defp history_lines(nil, _colors), do: []

  defp history_lines(history, colors) do
    parts =
      []
      |> maybe_append(history["pass_rate"], fn r -> "#{round(r * 100)}% pass rate" end)
      |> maybe_append(history["streak"], fn s -> "streak: #{s}" end)
      |> maybe_append(history["flaky"], fn _ -> "flaky" end)
      |> maybe_append(history["last_failed"], fn d ->
        "last failed #{format_blame_date(d)}"
      end)

    case parts do
      [] ->
        []

      _ ->
        [
          box_line("", colors),
          box_line("  #{colors.faint}#{Enum.join(parts, " · ")}#{colors.reset}", colors)
        ]
    end
  end

  defp maybe_append(list, nil, _fun), do: list
  defp maybe_append(list, false, _fun), do: list
  defp maybe_append(list, val, fun), do: list ++ [fun.(val)]

  defp regression_line(true, colors) do
    [
      box_line(
        "  #{colors.red}REGRESSION#{colors.reset} — this task was passing before",
        colors
      )
    ]
  end

  defp regression_line(_, _colors), do: []

  defp format_location(loc, colors) do
    file = loc["file"]
    line = loc["line"]
    loc_str = "#{file}:#{line}"
    sep_len = max(0, @box_width - String.length(loc_str) - 7)
    sep = String.duplicate("─", sep_len)

    header_line =
      box_line(
        "  #{colors.faint}── #{colors.cyan}#{loc_str}#{colors.reset} #{colors.faint}#{sep}#{colors.reset}",
        colors
      )

    message_lines =
      case loc["message"] do
        nil -> []
        msg -> [box_line("  #{colors.red}#{msg}#{colors.reset}", colors)]
      end

    source =
      case loc["source_lines"] do
        nil ->
          []

        src_lines ->
          Enum.map(src_lines, fn src_line ->
            if String.starts_with?(src_line, ">>") do
              box_line("  #{colors.red}#{src_line}#{colors.reset}", colors)
            else
              box_line("  #{colors.faint}#{src_line}#{colors.reset}", colors)
            end
          end) ++ [box_line("", colors)]
      end

    blame =
      case loc["blame"] do
        nil ->
          []

        b ->
          author = b["author"] || "unknown"
          date = format_blame_date(b["date"])
          msg = b["message"] || ""

          [
            box_line(
              "  #{colors.faint}#{author}, #{date}: \"#{msg}\"#{colors.reset}",
              colors
            ),
            box_line("", colors)
          ]
      end

    [header_line] ++ message_lines ++ [box_line("", colors)] ++ source ++ blame
  end

  defp format_diff(diff) do
    ref = diff["ref"]
    stat = diff["stat"]

    header = "#{IO.ANSI.faint()}Changes since last pass (#{ref}):#{IO.ANSI.reset()}"

    if stat && stat != "" do
      stat_lines =
        stat
        |> String.split("\n")
        |> Enum.map(fn line -> "  #{line}" end)
        |> Enum.join("\n")

      "#{header}\n#{stat_lines}"
    else
      header
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # BOX DRAWING (matches Error.Formatter patterns)
  # ─────────────────────────────────────────────────────────────────────────────

  defp build_colors do
    %{
      red: IO.ANSI.red(),
      yellow: IO.ANSI.yellow(),
      cyan: IO.ANSI.cyan(),
      green: IO.ANSI.green(),
      faint: IO.ANSI.faint(),
      reset: IO.ANSI.reset()
    }
  end

  defp box_line(content, colors) do
    visible = strip_ansi(content)
    visible_len = String.length(visible)
    max_len = @box_width - 2

    {display, display_len} =
      if visible_len > max_len do
        {String.slice(visible, 0, max_len - 3) <> "...", max_len}
      else
        {content, visible_len}
      end

    padding = String.duplicate(" ", max(0, @box_width - display_len - 1))
    "#{colors.faint}│#{colors.reset}#{display}#{padding}#{colors.faint}│#{colors.reset}"
  end

  defp strip_ansi(str) do
    Regex.replace(~r/\e\[[0-9;]*m/, str, "")
  end

  defp format_blame_date(nil), do: "unknown"

  defp format_blame_date(date_str) when is_binary(date_str) do
    case DateTime.from_iso8601(date_str) do
      {:ok, dt, _} ->
        diff = DateTime.diff(DateTime.utc_now(), dt, :second)
        format_relative_time(diff)

      _ ->
        date_str
    end
  end

  defp format_blame_date(_), do: "unknown"

  defp format_relative_time(seconds) when seconds < 60, do: "just now"
  defp format_relative_time(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m ago"
  defp format_relative_time(seconds) when seconds < 86400, do: "#{div(seconds, 3600)}h ago"
  defp format_relative_time(seconds), do: "#{div(seconds, 86400)}d ago"
end
