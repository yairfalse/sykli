defmodule Sykli.Detector do
  @moduledoc """
  Detects SDK files (sykli.go, sykli.rs, etc.) and runs them to emit JSON.
  """

  @sdk_files [
    {"sykli.go", &__MODULE__.run_go/1},
    {"sykli.rs", &__MODULE__.run_rust/1},
    {"sykli.ts", &__MODULE__.run_ts/1},
    {"sykli.exs", &__MODULE__.run_elixir/1}
  ]

  def find(path) do
    @sdk_files
    |> Enum.find_value(fn {file, runner} ->
      full_path = Path.join(path, file)
      if File.exists?(full_path), do: {:ok, {full_path, runner}}
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      nil -> {:error, :no_sdk_file}
    end
  end

  def emit({path, runner}) do
    runner.(path)
  end

  def run_go(path) do
    dir = Path.dirname(path)
    file = Path.basename(path)

    case System.cmd("go", ["run", file, "--emit"], cd: dir) do
      {output, 0} -> {:ok, output}
      {error, _} -> {:error, {:go_failed, error}}
    end
  end

  def run_rust(path) do
    dir = Path.dirname(path)
    bin = Path.join(dir, "sykli")
    cargo_toml = Path.join(dir, "Cargo.toml")

    cond do
      # Pre-compiled binary exists
      File.exists?(bin) ->
        case System.cmd(bin, ["--emit"], cd: dir, stderr_to_stdout: true) do
          {output, 0} -> {:ok, output}
          {error, _} -> {:error, {:rust_failed, error}}
        end

      # Cargo project with sykli feature - compile and run
      File.exists?(cargo_toml) ->
        case System.cmd("cargo", ["run", "--bin", "sykli", "--features", "sykli", "--", "--emit"],
               cd: dir,
               stderr_to_stdout: true
             ) do
          {output, 0} ->
            # cargo run outputs build info then JSON - extract just the JSON
            extract_json(output)

          {error, _} ->
            {:error, {:rust_cargo_failed, error}}
        end

      true ->
        {:error, :rust_binary_not_found}
    end
  end

  # Extract JSON from cargo output (skips compilation messages)
  defp extract_json(output) do
    # Find the JSON line (starts with { and contains "version")
    output
    |> String.split("\n")
    |> Enum.find(fn line ->
      trimmed = String.trim(line)
      String.starts_with?(trimmed, "{") && String.contains?(trimmed, "\"version\"")
    end)
    |> case do
      nil -> {:error, :no_json_in_output}
      json -> {:ok, json}
    end
  end

  def run_ts(path) do
    dir = Path.dirname(path)
    file = Path.basename(path)

    case System.cmd("npx", ["tsx", file, "--emit"], cd: dir, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {error, _} -> {:error, {:ts_failed, error}}
    end
  end

  def run_elixir(path) do
    dir = Path.dirname(path)
    file = Path.basename(path)

    # Run elixir script with --emit flag
    # The script should use `Mix.install([{:sykli, path: "..."}])` or have sykli available
    case System.cmd("elixir", [file, "--emit"], cd: dir, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {error, _} -> {:error, {:elixir_failed, error}}
    end
  end
end
