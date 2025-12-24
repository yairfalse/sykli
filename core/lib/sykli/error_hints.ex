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
    {~r/too many open files/i, "File descriptor limit - try: ulimit -n 4096"}
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
    |> Enum.map(fn hint -> "  #{IO.ANSI.yellow()}#{hint}#{IO.ANSI.reset()}" end)
    |> Enum.join("\n")
  end
end
