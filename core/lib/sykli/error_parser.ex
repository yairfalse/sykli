defmodule Sykli.ErrorParser do
  @moduledoc """
  Parses file:line locations from compiler, test, and lint output.

  Language-aware regex patterns extract structured location info from raw
  command output. This is the first step in building rich error context
  for AI consumption.

  ## Supported Patterns

  | Language   | Example                                   |
  |------------|-------------------------------------------|
  | Go         | `main.go:15:3: undefined: Foo`            |
  | Rust       | `--> src/main.rs:10:5`                    |
  | TypeScript | `src/app.ts(10,5): error TS2304`          |
  | Python     | `File "test_auth.py", line 15`            |
  | Elixir     | `lib/auth.ex:42: warning:`                |
  | Generic    | `file:line:col` (covers most linters)     |
  """

  @max_locations 5

  @type location :: %{
          file: String.t(),
          line: pos_integer(),
          column: pos_integer() | nil,
          message: String.t() | nil
        }

  @doc """
  Parses file:line locations from command output.

  Returns up to #{@max_locations} unique locations, deduped by file:line.
  """
  @spec parse(String.t()) :: [location()]
  def parse(output) when is_binary(output) do
    lines = String.split(output, "\n")

    # Use sliding pairs for Python lookahead (each element sees the next line)
    lines
    |> Enum.chunk_every(2, 1, [:eof])
    |> Enum.flat_map(&parse_pair/1)
    |> dedup_by_file_line()
    |> Enum.take(@max_locations)
  end

  def parse(_), do: []

  # ─────────────────────────────────────────────────────────────────────────────
  # LANGUAGE PATTERNS
  # ─────────────────────────────────────────────────────────────────────────────

  # Each parser returns nil or a location map.
  # Order matters: language-specific before generic.
  # Python needs the next line for message lookahead.

  defp parse_pair([line, next]) do
    line = String.trim(line)
    next = if next == :eof, do: nil, else: String.trim(next)

    parsers = [
      &parse_rust/1,
      fn l -> parse_python(l, next) end,
      &parse_typescript_parens/1,
      &parse_elixir_parens/1,
      &parse_generic/1
    ]

    case Enum.find_value(parsers, fn parser -> parser.(line) end) do
      nil -> []
      loc -> [loc]
    end
  end

  defp parse_pair([line]) do
    parse_pair([line, :eof])
  end

  # Rust: `--> src/main.rs:10:5`
  defp parse_rust(line) do
    case Regex.run(~r/^\s*--> (.+?):(\d+):(\d+)/, line) do
      [_, file, line_str, col_str] ->
        %{
          file: file,
          line: String.to_integer(line_str),
          column: String.to_integer(col_str),
          message: nil
        }

      _ ->
        nil
    end
  end

  # Python: `File "test_auth.py", line 15`
  # Message is on the next non-traceback line after the File reference.
  defp parse_python(line, next_line) do
    case Regex.run(~r/File "([^"]+)", line (\d+)/, line) do
      [_, file, line_str] ->
        %{
          file: file,
          line: String.to_integer(line_str),
          column: nil,
          message: extract_python_message(next_line)
        }

      _ ->
        nil
    end
  end

  defp extract_python_message(nil), do: nil

  defp extract_python_message(line) do
    trimmed = String.trim(line)

    if trimmed == "" or String.starts_with?(trimmed, "File ") do
      nil
    else
      trimmed
    end
  end

  # TypeScript/JS parenthesized: `src/app.ts(10,5): error TS2304: blah`
  defp parse_typescript_parens(line) do
    case Regex.run(~r/^(.+?)\((\d+),(\d+)\):\s*(.+)/, line) do
      [_, file, line_str, col_str, message] ->
        if looks_like_file?(file) do
          %{
            file: file,
            line: String.to_integer(line_str),
            column: String.to_integer(col_str),
            message: String.trim(message)
          }
        else
          nil
        end

      _ ->
        nil
    end
  end

  # Elixir parenthesized: `(lib/auth.ex:42)` or `** (CompileError) lib/auth.ex:42:`
  defp parse_elixir_parens(line) do
    case Regex.run(~r/\(([^\s()]+\.(?:exs?|erl|hrl)):(\d+)\)/, line) do
      [_, file, line_str] ->
        %{
          file: file,
          line: String.to_integer(line_str),
          column: nil,
          message: nil
        }

      _ ->
        nil
    end
  end

  # Generic: `file.ext:line:col: message` or `file.ext:line: message`
  # Covers Go, Elixir colon-style, most linters, gcc, etc.
  defp parse_generic(line) do
    case Regex.run(~r/^(.+?):(\d+):(\d+):\s*(.+)/, line) do
      [_, file, line_str, col_str, message] ->
        if looks_like_file?(file) do
          %{
            file: file,
            line: String.to_integer(line_str),
            column: String.to_integer(col_str),
            message: String.trim(message)
          }
        else
          nil
        end

      _ ->
        parse_generic_no_col(line)
    end
  end

  # file.ext:line: message (no column)
  defp parse_generic_no_col(line) do
    case Regex.run(~r/^(.+?):(\d+):\s+(.+)/, line) do
      [_, file, line_str, message] ->
        if looks_like_file?(file) do
          %{
            file: file,
            line: String.to_integer(line_str),
            column: nil,
            message: String.trim(message)
          }
        else
          nil
        end

      _ ->
        nil
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # HELPERS
  # ─────────────────────────────────────────────────────────────────────────────

  # Heuristic: does this look like a file path rather than a URL or label?
  # Requires a recognizable file extension (e.g. .go, .rs, .ts, .py, .ex, .c)
  # to filter out IP addresses, version numbers, and bare labels.
  @file_ext_pattern ~r/\.[a-zA-Z]{1,10}$/
  defp looks_like_file?(path) do
    not String.starts_with?(path, "http") and
      Regex.match?(@file_ext_pattern, path)
  end

  defp dedup_by_file_line(locations) do
    locations
    |> Enum.uniq_by(fn %{file: f, line: l} -> {f, l} end)
  end
end
