defmodule Sykli.Detector do
  @moduledoc """
  Detects SDK files (sykli.go, sykli.rs, etc.) and runs them to emit JSON.
  """

  @sdk_files [
    {"sykli.go", &__MODULE__.run_go/1},
    {"sykli.rs", &__MODULE__.run_rust/1},
    {"sykli.exs", &__MODULE__.run_elixir/1},
    {"sykli.ts", &__MODULE__.run_typescript/1},
    {"sykli.py", &__MODULE__.run_python/1}
  ]

  # SDK emission timeout (2 minutes - allows for compilation)
  @emit_timeout 120_000

  # Check if a command exists in PATH
  defp command_exists?(cmd) do
    case System.find_executable(cmd) do
      nil -> false
      _path -> true
    end
  end

  # Run a command with timeout to prevent hangs
  defp run_cmd(cmd, args, opts) do
    task =
      Task.async(fn ->
        System.cmd(cmd, args, opts)
      end)

    case Task.yield(task, @emit_timeout) || Task.shutdown(task) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
    end
  end

  def find(path) do
    # For Burrito-bundled binaries, the BEAM's cwd is the temp extraction dir.
    # Use PWD env var to get the actual shell working directory.
    abs_path =
      if path == "." do
        System.get_env("PWD") || File.cwd!()
      else
        Path.expand(path)
      end

    @sdk_files
    |> Enum.find_value(fn {file, runner} ->
      full_path = Path.join(abs_path, file)
      if File.exists?(full_path), do: {:ok, {full_path, runner}}
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      nil -> {:error, :no_sdk_file}
    end
  end

  @doc """
  Search one level of subdirectories for SDK files.
  Returns a list of relative paths like ["ci/sykli.rs", ".ci/sykli.go"].
  Used for "did you mean?" hints when no SDK file is found in the root.
  """
  def find_nearby(path) do
    abs_path =
      if path == "." do
        System.get_env("PWD") || File.cwd!()
      else
        Path.expand(path)
      end

    sdk_names = Enum.map(@sdk_files, fn {file, _runner} -> file end)

    case File.ls(abs_path) do
      {:ok, entries} ->
        entries
        |> Enum.filter(fn entry ->
          full = Path.join(abs_path, entry)
          File.dir?(full) and not String.starts_with?(entry, ".")
        end)
        |> Enum.flat_map(fn dir ->
          sdk_names
          |> Enum.filter(fn file ->
            File.exists?(Path.join([abs_path, dir, file]))
          end)
          |> Enum.map(fn file -> Path.join(dir, file) end)
        end)

      {:error, _} ->
        []
    end
  end

  def emit({path, runner}) do
    runner.(path)
  end

  def run_go(path) do
    if not command_exists?("go") do
      {:error, {:missing_tool, "go", "Install Go from https://go.dev/dl/"}}
    else
      dir = Path.dirname(path)
      file = Path.basename(path)

      case run_cmd("go", ["run", file, "--emit"], cd: dir, stderr_to_stdout: true) do
        {output, 0} ->
          # go run outputs download messages then JSON - extract just the JSON
          extract_json(output)

        {:error, :timeout} ->
          {:error, {:go_timeout, "SDK emission timed out after 2 minutes"}}

        {error, _} ->
          {:error, {:go_failed, error}}
      end
    end
  end

  def run_rust(path) do
    dir = Path.dirname(path)
    bin = Path.join(dir, "sykli")
    cargo_toml = Path.join(dir, "Cargo.toml")

    cond do
      # Pre-compiled binary exists
      File.exists?(bin) ->
        case run_cmd(bin, ["--emit"], cd: dir, stderr_to_stdout: true) do
          {output, 0} -> {:ok, output}
          {:error, :timeout} -> {:error, {:rust_timeout, "SDK emission timed out"}}
          {error, _} -> {:error, {:rust_failed, error}}
        end

      # Cargo project - compile and run
      File.exists?(cargo_toml) ->
        if not command_exists?("cargo") do
          {:error, {:missing_tool, "cargo", "Install Rust from https://rustup.rs/"}}
        else
          # Try without --features first, fall back to --features sykli
          case run_cargo_emit(dir) do
            {:ok, _} = ok ->
              ok

            {:error, :timeout} ->
              {:error, {:rust_timeout, "Cargo build timed out after 2 minutes"}}

            {:error, _} ->
              case run_cargo_emit(dir, ["--features", "sykli"]) do
                {:ok, _} = ok -> ok
                {:error, :timeout} -> {:error, {:rust_timeout, "Cargo build timed out after 2 minutes"}}
                {:error, error} -> {:error, {:rust_cargo_failed, error}}
              end
          end
        end

      true ->
        {:error, :rust_binary_not_found}
    end
  end

  defp run_cargo_emit(dir, extra_args \\ []) do
    args = ["run", "--bin", "sykli"] ++ extra_args ++ ["--", "--emit"]

    case run_cmd("cargo", args, cd: dir, stderr_to_stdout: true) do
      {output, 0} -> extract_json(output)
      {:error, :timeout} -> {:error, :timeout}
      {error, _} -> {:error, error}
    end
  end

  # Extract JSON from SDK output (skips compilation messages, log lines, etc.)
  # Handles both single-line and multi-line (pretty-printed) JSON.
  defp extract_json(output) do
    # First try: single-line JSON (fast path)
    single_line =
      output
      |> String.split("\n")
      |> Enum.find(fn line ->
        trimmed = String.trim(line)
        String.starts_with?(trimmed, "{") && String.contains?(trimmed, "\"version\"")
      end)

    if single_line do
      {:ok, single_line}
    else
      # Multi-line JSON: find the first '{' and extract the full JSON object
      case extract_multiline_json(output) do
        nil -> {:error, :no_json_in_output}
        json -> {:ok, json}
      end
    end
  end

  defp extract_multiline_json(output) do
    lines = String.split(output, "\n")
    # Find the index of the first line starting with '{'
    start_idx = Enum.find_index(lines, fn line -> String.trim(line) == "{" end)

    if start_idx do
      # Collect lines from '{' until braces balance
      lines
      |> Enum.drop(start_idx)
      |> Enum.reduce_while({0, []}, fn line, {depth, acc} ->
        new_depth =
          depth +
            (line |> String.graphemes() |> Enum.count(&(&1 == "{"))) -
            (line |> String.graphemes() |> Enum.count(&(&1 == "}")))

        acc = [line | acc]

        if new_depth == 0 do
          {:halt, {:done, Enum.reverse(acc)}}
        else
          {:cont, {new_depth, acc}}
        end
      end)
      |> case do
        {:done, json_lines} -> Enum.join(json_lines, "\n")
        _ -> nil
      end
    else
      nil
    end
  end

  def run_elixir(path) do
    if not command_exists?("elixir") do
      {:error,
       {:missing_tool, "elixir", "Install Elixir from https://elixir-lang.org/install.html"}}
    else
      dir = Path.dirname(path)
      file = Path.basename(path)

      # Run elixir script with --emit flag
      # The script should use `Mix.install([{:sykli, path: "..."}])` or have sykli available
      case run_cmd("elixir", [file, "--emit"], cd: dir, stderr_to_stdout: true) do
        {output, 0} ->
          # Extract JSON from output (Logger.debug messages may be mixed in)
          extract_json(output)

        {:error, :timeout} ->
          {:error, {:elixir_timeout, "SDK emission timed out after 2 minutes"}}

        {error, _} ->
          {:error, {:elixir_failed, error}}
      end
    end
  end

  def run_typescript(path) do
    if not command_exists?("npx") do
      {:error, {:missing_tool, "npx", "Install Node.js from https://nodejs.org/"}}
    else
      dir = Path.dirname(path)
      file = Path.basename(path)

      # Try tsx first (faster), fall back to ts-node
      runner = if tsx_available?(), do: "tsx", else: "ts-node"

      case run_cmd("npx", [runner, file, "--emit"], cd: dir, stderr_to_stdout: true) do
        {output, 0} ->
          extract_json(output)

        {:error, :timeout} ->
          {:error, {:typescript_timeout, "SDK emission timed out after 2 minutes"}}

        {error, _} ->
          {:error, {:typescript_failed, error}}
      end
    end
  end

  defp tsx_available? do
    # Quick check with short timeout (5 seconds)
    task =
      Task.async(fn ->
        System.cmd("npx", ["tsx", "--version"], stderr_to_stdout: true)
      end)

    case Task.yield(task, 5_000) || Task.shutdown(task) do
      {:ok, {_, 0}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  def run_python(path) do
    runner =
      cond do
        command_exists?("python3") -> "python3"
        command_exists?("python") -> "python"
        true -> nil
      end

    if runner == nil do
      {:error, {:missing_tool, "python", "Install Python from https://python.org/"}}
    else
      dir = Path.dirname(path)
      file = Path.basename(path)

      case run_cmd(runner, [file, "--emit"], cd: dir, stderr_to_stdout: true) do
        {output, 0} ->
          extract_json(output)

        {:error, :timeout} ->
          {:error, {:python_timeout, "SDK emission timed out after 2 minutes"}}

        {error, _} ->
          {:error, {:python_failed, error}}
      end
    end
  end
end
