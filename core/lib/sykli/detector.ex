defmodule Sykli.Detector do
  @moduledoc """
  Detects SDK files (sykli.go, sykli.rs, etc.) and runs them to emit JSON.
  """

  @sdk_files [
    {"sykli.go", &__MODULE__.run_go/1},
    {"sykli.rs", &__MODULE__.run_rust/1},
    {"sykli.ts", &__MODULE__.run_ts/1}
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
    # For now, assume sykli.rs is a script that can be run with cargo-script
    # or pre-compiled. MVP: expect a sykli binary next to sykli.rs
    dir = Path.dirname(path)
    bin = Path.join(dir, "sykli")

    if File.exists?(bin) do
      case System.cmd(bin, ["--emit"], cd: dir, stderr_to_stdout: true) do
        {output, 0} -> {:ok, output}
        {error, _} -> {:error, {:rust_failed, error}}
      end
    else
      {:error, :rust_binary_not_found}
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
end
