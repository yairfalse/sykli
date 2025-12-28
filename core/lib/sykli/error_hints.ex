defmodule Sykli.ErrorHints do
  @moduledoc """
  Provides helpful hints for common errors.
  Analyzes exit codes and output patterns to suggest fixes.
  """

  # ----- EXIT CODE HINTS -----

  @doc """
  Returns a hint for a given exit code, or nil if no specific hint.
  """
  def for_exit_code(code) when is_integer(code) do
    case code do
      # Too generic
      1 ->
        nil

      2 ->
        "Command misuse - check arguments"

      126 ->
        "Not executable - try: chmod +x <script>"

      127 ->
        "Command not found - check PATH or install missing tool"

      128 ->
        "Invalid exit code"

      137 ->
        "Process killed (SIGKILL) - likely out of memory (OOM)"

      143 ->
        "Process terminated (SIGTERM) - task was cancelled"

      code when code > 128 and code < 256 ->
        signal = code - 128
        "Process killed by signal #{signal}"

      _ ->
        nil
    end
  end

  # ----- OUTPUT PATTERN HINTS -----

  @patterns [
    # Command/executable issues
    {~r/command not found/i, "Install the missing command or check your PATH"},
    {~r/not found in PATH/i, "Install the missing tool or add it to PATH"},
    {~r/permission denied/i, "Check file permissions - try: chmod +x <file>"},
    {~r/no such file or directory/i, "File or directory doesn't exist - check the path"},

    # Network issues
    {~r/connection refused/i, "Service not running - start the service or check the port"},
    {~r/dial tcp.*connect:/i, "Network connection failed - check if service is running"},
    {~r/no such host/i, "DNS resolution failed - check hostname"},
    {~r/timeout|timed out/i, "Operation timed out - increase timeout or check network"},
    {~r/context deadline exceeded/i, "Request timed out - service may be slow or unresponsive"},

    # Docker issues
    {~r/Unable to find image/i,
     "Docker image not found - check image name or run: docker pull <image>"},
    {~r/Cannot connect to the Docker daemon/i, "Docker not running - start Docker"},
    {~r/docker: Error response from daemon/i, "Docker error - check container logs"},

    # Go issues
    {~r/cannot find module providing package/i, "Missing Go module - try: go mod tidy"},
    {~r/go: go\.mod file not found/i, "Not a Go module - try: go mod init"},
    {~r/build constraints exclude all Go files/i, "No Go files match build tags"},

    # Node/npm issues
    {~r/Cannot find module/i, "Missing npm module - try: npm install"},
    {~r/npm ERR! missing script/i, "Script not found in package.json"},
    {~r/ENOENT.*package\.json/i, "No package.json - try: npm init"},

    # Rust/Cargo issues
    {~r/error\[E0432\].*unresolved import/i, "Missing Rust dependency - check Cargo.toml"},
    {~r/error\[E0433\].*failed to resolve/i, "Unresolved Rust module - check imports"},
    {~r/could not find.*in.*registry/i, "Crate not found - check Cargo.toml"},

    # Python issues
    {~r/ModuleNotFoundError/i, "Missing Python module - try: pip install <module>"},
    {~r/No module named/i, "Missing Python module - try: pip install <module>"},

    # Generic build issues
    {~r/out of memory/i, "Out of memory - reduce parallelism or increase memory"},
    {~r/disk quota exceeded/i, "Disk full - free up space"},
    {~r/too many open files/i, "File descriptor limit - try: ulimit -n 4096"},

    # Test failures
    {~r/FAIL:/i, "Test failed - check test output above"},
    {~r/--- FAIL:/i, "Go test failed - check test output above"},
    {~r/test result: FAILED/i, "Rust test failed - check test output above"},
    {~r/\d+ tests?, \d+ failures?/i, "Tests failed - review failures above"},

    # Compilation errors
    {~r/syntax error/i, "Syntax error - check file for typos"},
    {~r/type error/i, "Type error - check type annotations"},
    {~r/undefined reference/i, "Linker error - check for missing libraries"},

    # Git issues
    {~r/not a git repository/i, "Not in a git repo - run: git init"},
    {~r/fatal: could not read from remote/i, "Git auth failed - check SSH keys or credentials"},

    # Elixir issues
    {~r/\*\* \(CompileError\)/i, "Elixir compile error - check syntax"},
    {~r/\*\* \(UndefinedFunctionError\)/i, "Function not defined - check module imports"},
    {~r/\*\* \(ArgumentError\)/i, "Invalid argument - check function parameters"}
  ]

  @doc """
  Returns a hint based on output patterns, or nil if no match.
  """
  def for_output(output) when is_binary(output) do
    Enum.find_value(@patterns, fn {pattern, hint} ->
      if Regex.match?(pattern, output), do: hint
    end)
  end

  def for_output(_), do: nil

  # ----- COMBINED HINTS -----

  @doc """
  Returns all applicable hints for an error.
  Combines exit code hints and output pattern hints.
  """
  def get_hints(exit_code, output \\ "") do
    hints = []

    # Add exit code hint
    hints =
      case for_exit_code(exit_code) do
        nil -> hints
        hint -> [hint | hints]
      end

    # Add output pattern hint
    hints =
      case for_output(output) do
        nil -> hints
        hint -> [hint | hints]
      end

    Enum.reverse(hints) |> Enum.uniq()
  end

  @doc """
  Formats hints for display.
  """
  def format_hints([]), do: ""

  def format_hints(hints) do
    hints
    |> Enum.map(fn hint -> "  #{IO.ANSI.yellow()}> #{hint}#{IO.ANSI.reset()}" end)
    |> Enum.join("\n")
  end

  # ----- DID YOU MEAN -----

  @doc """
  Suggests similar items using Jaro distance.
  Returns nil if no good match or exact match, or "Did you mean 'closest'?" if found.
  """
  def did_you_mean(input, candidates, threshold \\ 0.8) when is_list(candidates) do
    input_str = to_string(input)

    best =
      candidates
      |> Enum.map(fn c -> {c, jaro_distance(input_str, to_string(c))} end)
      |> Enum.max_by(fn {_, score} -> score end, fn -> {nil, 0} end)

    case best do
      # Don't suggest if exact match (score == 1.0)
      {candidate, score} when score >= threshold and score < 1.0 ->
        "Did you mean '#{candidate}'?"

      _ ->
        nil
    end
  end

  # Jaro distance implementation (simple version)
  defp jaro_distance(s1, s2) when s1 == s2, do: 1.0
  defp jaro_distance("", _), do: 0.0
  defp jaro_distance(_, ""), do: 0.0

  defp jaro_distance(s1, s2) do
    len1 = String.length(s1)
    len2 = String.length(s2)
    match_distance = max(div(max(len1, len2), 2) - 1, 0)

    s1_chars = String.graphemes(s1)
    s2_chars = String.graphemes(s2)

    {matches, transpositions} = find_matches(s1_chars, s2_chars, match_distance)

    if matches == 0 do
      0.0
    else
      (matches / len1 + matches / len2 + (matches - transpositions / 2) / matches) / 3
    end
  end

  defp find_matches(s1_chars, s2_chars, match_distance) do
    len2 = length(s2_chars)
    s2_matched = :array.new(len2, default: false)

    {matches, s1_matched_chars, s2_matched} =
      s1_chars
      |> Enum.with_index()
      |> Enum.reduce({0, [], s2_matched}, fn {c1, i}, {m, matched, s2m} ->
        start = max(0, i - match_distance)
        stop = min(i + match_distance + 1, len2)

        case find_match_in_range(c1, s2_chars, start, stop, s2m) do
          {:found, j, new_s2m} ->
            {m + 1, [{c1, j} | matched], new_s2m}

          :not_found ->
            {m, matched, s2m}
        end
      end)

    # Count transpositions
    s2_matched_chars =
      s2_chars
      |> Enum.with_index()
      |> Enum.filter(fn {_, j} -> :array.get(j, s2_matched) end)
      |> Enum.map(fn {c, _} -> c end)

    s1_matched_sorted = s1_matched_chars |> Enum.reverse() |> Enum.map(fn {c, _} -> c end)

    transpositions =
      Enum.zip(s1_matched_sorted, s2_matched_chars)
      |> Enum.count(fn {a, b} -> a != b end)

    {matches, transpositions}
  end

  defp find_match_in_range(c1, s2_chars, start, stop, s2_matched) do
    start..(stop - 1)
    |> Enum.reduce_while(:not_found, fn j, _ ->
      c2 = Enum.at(s2_chars, j)

      if c1 == c2 and not :array.get(j, s2_matched) do
        {:halt, {:found, j, :array.set(j, true, s2_matched)}}
      else
        {:cont, :not_found}
      end
    end)
  end
end
