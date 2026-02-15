defmodule Sykli.Error.Formatter do
  @moduledoc """
  Rust-style error formatting for beautiful terminal output.

  Produces output like:

  ```
  ╭─ error[E001]: task 'build' failed ───────────────────────╮
  │                                                          │
  │  Command exited with code 1:                             │
  │                                                          │
  │    → go build -o app ./...                               │
  │                                                          │
  │  ─────────────────────────────────────────────────────── │
  │  │ ./main.go:15:2: undefined: fmt.Prinltn               │
  │  ─────────────────────────────────────────────────────── │
  │                                                          │
  │  help: fix the compilation error above                   │
  │  note: task ran for 1.2s before failing                  │
  │                                                          │
  ╰──────────────────────────────────────────────────────────╯
  ```
  """

  alias Sykli.Error

  @box_width 60

  # Error type colors
  defp type_color(:execution), do: IO.ANSI.red()
  defp type_color(:validation), do: IO.ANSI.red()
  defp type_color(:sdk), do: IO.ANSI.red()
  defp type_color(:runtime), do: IO.ANSI.red()
  defp type_color(:internal), do: IO.ANSI.magenta()
  defp type_color(_), do: IO.ANSI.red()

  @doc """
  Formats an error for terminal display.

  Options:
  - `no_color` - disable ANSI colors (default: false)
  - `max_output_lines` - max lines of command output to show (default: 10)
  - `compact` - use compact single-line format (default: false)
  """
  def format(%Error{} = error, opts \\ []) do
    no_color = Keyword.get(opts, :no_color, false)
    compact = Keyword.get(opts, :compact, false)

    if compact do
      format_compact(error, no_color)
    else
      format_full(error, opts)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # COMPACT FORMAT
  # ─────────────────────────────────────────────────────────────────────────────

  defp format_compact(%Error{code: code, message: message}, no_color) do
    red = if no_color, do: "", else: IO.ANSI.red()
    reset = if no_color, do: "", else: IO.ANSI.reset()
    faint = if no_color, do: "", else: IO.ANSI.faint()

    "#{red}error[#{code}]#{reset}: #{message} #{faint}(run with --verbose for details)#{reset}"
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # FULL FORMAT (BOX STYLE)
  # ─────────────────────────────────────────────────────────────────────────────

  defp format_full(%Error{} = error, opts) do
    no_color = Keyword.get(opts, :no_color, false)
    max_output_lines = Keyword.get(opts, :max_output_lines, 10)

    # Color helpers
    colors = build_colors(no_color)

    # Build the box
    lines = []

    # Header line
    header = build_header(error, colors)
    lines = lines ++ [header]

    # Empty line
    lines = lines ++ [box_line("", colors)]

    # Task context (if present)
    lines =
      if error.task do
        lines ++ [box_line("  Task: #{error.task}", colors)]
      else
        lines
      end

    # Step context (if present)
    lines =
      if error.step do
        lines ++ [box_line("  Step: #{error.step}", colors)]
      else
        lines
      end

    # Add empty line after context if we had any
    lines =
      if error.task || error.step do
        lines ++ [box_line("", colors)]
      else
        lines
      end

    # Exit code (for execution errors)
    lines =
      if error.exit_code do
        (lines ++ [box_line("  Command exited with code #{error.exit_code}:", colors)])
        |> then(&(&1 ++ [box_line("", colors)]))
      else
        lines
      end

    # Command (if present)
    lines =
      if error.command do
        cmd_line = "    #{colors.cyan}→ #{error.command}#{colors.reset}"

        (lines ++ [box_line_raw(cmd_line, colors)])
        |> then(&(&1 ++ [box_line("", colors)]))
      else
        lines
      end

    # Output (if present, with separator)
    lines =
      if error.output && String.trim(error.output) != "" do
        output_lines = format_output(error.output, max_output_lines, colors)
        separator = "  " <> String.duplicate("─", @box_width - 6)

        lines ++
          [box_line(separator, colors)] ++
          output_lines ++
          [box_line(separator, colors)] ++
          [box_line("", colors)]
      else
        lines
      end

    # Hints
    lines =
      Enum.reduce(error.hints, lines, fn hint, acc ->
        acc ++ [box_line("  #{colors.yellow}help#{colors.reset}: #{hint}", colors)]
      end)

    # Notes
    lines =
      Enum.reduce(error.notes, lines, fn note, acc ->
        acc ++ [box_line("  #{colors.faint}note#{colors.reset}: #{note}", colors)]
      end)

    # Empty line before close
    lines = lines ++ [box_line("", colors)]

    # Footer
    footer = build_footer(colors)
    lines = lines ++ [footer]

    Enum.join(lines, "\n")
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # BOX DRAWING
  # ─────────────────────────────────────────────────────────────────────────────

  defp build_colors(no_color) do
    if no_color do
      %{
        red: "",
        yellow: "",
        cyan: "",
        magenta: "",
        faint: "",
        reset: "",
        bright: ""
      }
    else
      %{
        red: IO.ANSI.red(),
        yellow: IO.ANSI.yellow(),
        cyan: IO.ANSI.cyan(),
        magenta: IO.ANSI.magenta(),
        faint: IO.ANSI.faint(),
        reset: IO.ANSI.reset(),
        bright: IO.ANSI.bright()
      }
    end
  end

  defp build_header(%Error{code: code, type: type, message: message}, colors) do
    type_col = type_color(type)
    type_col = if colors.reset == "", do: "", else: type_col

    # Calculate visible length and truncate if needed
    visible_text = "error[#{code}]: #{message}"
    # Leave room for "╭─ " and " ─╮"
    max_header_len = @box_width - 6

    {display_text, display_msg} =
      if String.length(visible_text) > max_header_len do
        # Truncate message to fit
        code_prefix = "error[#{code}]: "
        max_msg_len = max_header_len - String.length(code_prefix) - 3
        truncated_msg = String.slice(message, 0, max(0, max_msg_len)) <> "..."
        {"error[#{code}]: #{truncated_msg}", truncated_msg}
      else
        {visible_text, message}
      end

    # Header text with colors
    header_text = "#{type_col}error[#{code}]#{colors.reset}: #{display_msg}"
    visible_len = String.length(display_text)

    # Build the header line with box drawing
    # ╭─ error[task_failed]: message ─────────────╮
    padding_len = max(0, @box_width - visible_len - 4)
    padding = String.duplicate("─", padding_len)

    "#{colors.faint}╭─#{colors.reset} #{header_text} #{colors.faint}#{padding}╮#{colors.reset}"
  end

  defp build_footer(colors) do
    line = String.duplicate("─", @box_width)
    "#{colors.faint}╰#{line}╯#{colors.reset}"
  end

  defp box_line(content, colors) do
    # Calculate visible length (strip ANSI for length calc)
    visible_content = strip_ansi(content)
    visible_len = String.length(visible_content)
    # Room for │ on each side
    max_content_len = @box_width - 2

    # Truncate if too long
    {display_content, display_len} =
      if visible_len > max_content_len do
        truncated = String.slice(visible_content, 0, max_content_len - 3) <> "..."
        {truncated, String.length(truncated)}
      else
        {content, visible_len}
      end

    padding_len = max(0, @box_width - display_len - 1)
    padding = String.duplicate(" ", padding_len)

    "#{colors.faint}│#{colors.reset}#{display_content}#{padding}#{colors.faint}│#{colors.reset}"
  end

  # For lines that already have ANSI codes
  defp box_line_raw(content, colors) do
    visible_content = strip_ansi(content)
    visible_len = String.length(visible_content)
    max_content_len = @box_width - 2

    # Truncate if too long (strip ANSI, truncate, lose colors - acceptable for long lines)
    {display_content, display_len} =
      if visible_len > max_content_len do
        truncated = String.slice(visible_content, 0, max_content_len - 3) <> "..."
        {truncated, String.length(truncated)}
      else
        {content, visible_len}
      end

    padding_len = max(0, @box_width - display_len - 1)
    padding = String.duplicate(" ", padding_len)

    "#{colors.faint}│#{colors.reset}#{display_content}#{padding}#{colors.faint}│#{colors.reset}"
  end

  defp strip_ansi(str) do
    # Remove ANSI escape codes for length calculation
    Regex.replace(~r/\e\[[0-9;]*m/, str, "")
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # OUTPUT FORMATTING
  # ─────────────────────────────────────────────────────────────────────────────

  defp format_output(output, max_lines, colors) do
    lines =
      output
      |> String.trim()
      |> String.split("\n")
      |> Enum.take(-max_lines)

    lines
    |> Enum.map(fn line ->
      # Truncate long lines
      truncated =
        if String.length(line) > @box_width - 8 do
          String.slice(line, 0, @box_width - 11) <> "..."
        else
          line
        end

      # Highlight error keywords
      highlighted = highlight_errors(truncated, colors)

      box_line_raw("  #{colors.faint}│#{colors.reset} #{highlighted}", colors)
    end)
  end

  @error_keywords ~w(error failed failure panic exception undefined cannot denied rejected timeout FAIL Error)

  defp highlight_errors(line, colors) do
    if contains_error_keyword?(line) do
      "#{colors.red}#{line}#{colors.reset}"
    else
      line
    end
  end

  defp contains_error_keyword?(line) do
    lower = String.downcase(line)
    Enum.any?(@error_keywords, fn kw -> String.contains?(lower, String.downcase(kw)) end)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # SIMPLE FORMAT (for non-boxed output)
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Formats an error in simple Rust-style (without box).

  ```
  error[E001]: task 'build' failed
    --> exit code: 1

    $ go build ./...

    ./main.go:15: undefined: fmt.Prinltn

    = help: fix the compilation error above
    = note: ran for 1.2s
  ```
  """
  def format_simple(%Error{} = error, opts \\ []) do
    no_color = Keyword.get(opts, :no_color, false)
    max_output_lines = Keyword.get(opts, :max_output_lines, 10)

    colors = build_colors(no_color)
    type_col = if no_color, do: "", else: type_color(error.type)

    lines = []

    # Header
    header = "#{type_col}error[#{error.code}]#{colors.reset}: #{error.message}"
    lines = lines ++ [header]

    # Context arrow
    context_parts = []

    context_parts =
      if error.task, do: context_parts ++ ["task: #{error.task}"], else: context_parts

    context_parts =
      if error.exit_code,
        do: context_parts ++ ["exit code: #{error.exit_code}"],
        else: context_parts

    lines =
      if context_parts != [] do
        lines ++ ["  #{colors.cyan}-->#{colors.reset} #{Enum.join(context_parts, ", ")}"]
      else
        lines
      end

    # Command
    lines =
      if error.command do
        lines ++ ["", "  #{colors.faint}$#{colors.reset} #{error.command}"]
      else
        lines
      end

    # Output
    lines =
      if error.output && String.trim(error.output) != "" do
        output_lines =
          error.output
          |> String.trim()
          |> String.split("\n")
          |> Enum.take(-max_output_lines)
          |> Enum.map(fn line ->
            highlighted = highlight_errors(line, colors)
            "  #{colors.faint}│#{colors.reset} #{highlighted}"
          end)

        lines ++ [""] ++ output_lines
      else
        lines
      end

    # Locations (file:line from parsed output)
    lines =
      if error.locations != [] do
        loc_lines =
          Enum.map(error.locations, fn loc ->
            loc_str = "#{loc.file}:#{loc.line}"

            if loc.message do
              "  #{colors.cyan}-->#{colors.reset} #{loc_str} — #{loc.message}"
            else
              "  #{colors.cyan}-->#{colors.reset} #{loc_str}"
            end
          end)

        lines ++ [""] ++ loc_lines
      else
        lines
      end

    # Hints
    lines =
      Enum.reduce(error.hints, lines, fn hint, acc ->
        acc ++
          ["", "  #{colors.faint}=#{colors.reset} #{colors.yellow}help#{colors.reset}: #{hint}"]
      end)

    # Notes
    lines =
      Enum.reduce(error.notes, lines, fn note, acc ->
        acc ++ ["  #{colors.faint}= note#{colors.reset}: #{note}"]
      end)

    Enum.join(lines, "\n")
  end
end
