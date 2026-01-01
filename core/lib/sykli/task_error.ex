defmodule Sykli.TaskError do
  @moduledoc """
  Structured error for task failures with full context.
  Provides task name, command, exit code, output, duration, and hints.
  """

  defstruct [:task, :command, :exit_code, :output, :duration_ms, :hints]

  @type t :: %__MODULE__{
          task: String.t(),
          command: String.t(),
          exit_code: integer(),
          output: String.t(),
          duration_ms: integer(),
          hints: [String.t()]
        }

  @doc """
  Creates a new TaskError with automatic hint generation.
  """
  def new(opts) do
    task = Keyword.fetch!(opts, :task)
    command = Keyword.fetch!(opts, :command)
    exit_code = Keyword.fetch!(opts, :exit_code)
    output = Keyword.fetch!(opts, :output)
    duration_ms = Keyword.fetch!(opts, :duration_ms)

    hints = Sykli.ErrorHints.get_hints(exit_code, output)

    %__MODULE__{
      task: task,
      command: command,
      exit_code: exit_code,
      output: output,
      duration_ms: duration_ms,
      hints: hints
    }
  end

  @doc """
  Formats the error for display.

  Options:
    - max_lines: maximum output lines to show (default: 10)
    - no_color: disable ANSI colors (default: false)
  """
  def format(%__MODULE__{} = error, opts \\ []) do
    max_lines = Keyword.get(opts, :max_lines, 10)
    no_color = Keyword.get(opts, :no_color, false)

    # Color helpers
    red = if no_color, do: "", else: IO.ANSI.red()
    yellow = if no_color, do: "", else: IO.ANSI.yellow()
    faint = if no_color, do: "", else: IO.ANSI.faint()
    reset = if no_color, do: "", else: IO.ANSI.reset()
    cyan = if no_color, do: "", else: IO.ANSI.cyan()

    # Build output sections
    sections = []

    # Header: task name and exit code
    header =
      "#{red}✗ #{error.task}#{reset} #{faint}(exit #{error.exit_code}) #{format_duration(error.duration_ms)}#{reset}"

    sections = [header | sections]

    # Command that was run
    command_line = "#{faint}  → #{cyan}#{error.command}#{reset}"
    sections = [command_line | sections]

    # Last N lines of output with error highlighting
    sections =
      if error.output && error.output != "" do
        output_lines =
          error.output
          |> String.trim()
          |> String.split("\n")
          |> Enum.take(-max_lines)

        if length(output_lines) > 0 do
          output_section =
            output_lines
            |> Enum.map(fn line ->
              highlighted = highlight_errors(line, red, reset)
              "  #{faint}│#{reset} #{highlighted}"
            end)
            |> Enum.join("\n")

          # Extract the key error line for summary
          key_error = extract_key_error(error.output)

          base_sections =
            ["#{faint}  ─────────────────────────────────#{reset}" | sections]
            |> then(&[output_section | &1])
            |> then(&["#{faint}  ─────────────────────────────────#{reset}" | &1])

          # Add key error summary if found
          if key_error do
            ["  #{red}► #{key_error}#{reset}" | base_sections]
          else
            base_sections
          end
        else
          sections
        end
      else
        sections
      end

    # Hints
    sections =
      if length(error.hints) > 0 do
        hint_lines =
          error.hints
          |> Enum.map(&"  #{yellow}💡 #{&1}#{reset}")
          |> Enum.join("\n")

        [hint_lines | sections]
      else
        sections
      end

    sections
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"

  defp format_duration(ms) do
    seconds = ms / 1000
    "#{Float.round(seconds, 1)}s"
  end

  # Error patterns to highlight
  @error_patterns [
    ~r/\berror\b/i,
    ~r/\bfailed\b/i,
    ~r/\bfailure\b/i,
    ~r/\bpanic\b/i,
    ~r/\bexception\b/i,
    ~r/\bundefined\b/i,
    ~r/\bsegmentation fault\b/i,
    ~r/\bcannot\b/i,
    ~r/\bnot found\b/i,
    ~r/\bdenied\b/i,
    ~r/\brejected\b/i,
    ~r/\btimeout\b/i,
    ~r/\b✗\b/
  ]

  # Highlight error keywords in a line
  defp highlight_errors(line, red, reset) do
    if contains_error?(line) do
      "#{red}#{line}#{reset}"
    else
      line
    end
  end

  defp contains_error?(line) do
    Enum.any?(@error_patterns, fn pattern ->
      Regex.match?(pattern, line)
    end)
  end

  # Key error patterns - more specific, used for summary
  @key_error_patterns [
    # Go
    ~r/^.*?:\d+:\d+:.*error.*/i,
    ~r/panic:.*/i,
    # Rust
    ~r/^error\[E\d+\]:.*/,
    ~r/thread '.*' panicked.*/,
    # Elixir
    ~r/\*\* \(.+Error\).*/,
    ~r/\(CompileError\).*/,
    # JavaScript/TypeScript
    ~r/TypeError:.*/,
    ~r/ReferenceError:.*/,
    ~r/SyntaxError:.*/,
    # Python
    ~r/^\w+Error:.*/,
    ~r/Traceback \(most recent call last\).*/,
    # Generic test failures
    ~r/FAILED.*/,
    ~r/FAIL:.*/,
    ~r/assertion failed.*/i,
    ~r/expected .* but got.*/i
  ]

  # Extract the most important error line
  defp extract_key_error(output) do
    output
    |> String.split("\n")
    |> Enum.find(fn line ->
      line = String.trim(line)
      line != "" and Enum.any?(@key_error_patterns, &Regex.match?(&1, line))
    end)
    |> case do
      nil -> nil
      line -> String.trim(line) |> String.slice(0, 100)
    end
  end
end
