defmodule Sykli.CLI.Lock do
  @moduledoc """
  `sykli lock` command.
  """

  alias Sykli.CLI.JsonResponse
  alias Sykli.ContractLock
  alias Sykli.Error
  alias Sykli.Error.Formatter

  def run(args, runtime_opts \\ []) do
    {opts, path} = parse(args)
    path = path || "."

    if Keyword.get(opts, :help, false) do
      print_help()
      0
    else
      execute(path, opts, runtime_opts)
    end
  end

  defp execute(path, opts, runtime_opts) do
    json? = Keyword.get(opts, :json, false)

    with {:ok, {sdk_file, _runner} = sdk} <- detector(runtime_opts).find(path),
         {:ok, current} <- ContractLock.double_emit(fn -> emit(runtime_opts, sdk) end),
         lock <- ContractLock.build(current.contract, sdk_file),
         lock_path <- ContractLock.lock_path_for_sdk(sdk_file),
         old_hash <- existing_hash(lock_path),
         {:ok, _bytes} <- ContractLock.write(lock, lock_path) do
      data = %{
        hash: lock["contract_hash"],
        schema_version: lock["schema_version"],
        sdk_file: lock["sdk_file"],
        changed: old_hash != lock["contract_hash"]
      }

      if json? do
        IO.puts(JsonResponse.ok(data))
      else
        IO.puts("Locked contract #{lock["contract_hash"]}")
      end

      0
    else
      {:error, reason} ->
        output_error(reason, json?)
    end
  end

  defp existing_hash(path) do
    case ContractLock.read(path) do
      {:ok, lock} -> lock["contract_hash"]
      {:error, _} -> nil
    end
  end

  defp emit(opts, sdk) do
    case Keyword.get(opts, :emit_fun) do
      fun when is_function(fun, 1) -> fun.(sdk)
      _ -> detector(opts).emit(sdk)
    end
  end

  defp detector(opts), do: Keyword.get(opts, :detector, Sykli.Detector)

  defp output_error(reason, json?) do
    error = Error.wrap(reason)

    if json? do
      IO.puts(JsonResponse.error(error))
    else
      IO.puts(Formatter.format(error))
    end

    1
  end

  defp parse(args) do
    Enum.reduce(args, {[], []}, fn
      "--json", {opts, rest} -> {[json: true] ++ opts, rest}
      "--help", {opts, rest} -> {[help: true] ++ opts, rest}
      "-h", {opts, rest} -> {[help: true] ++ opts, rest}
      <<"--", _::binary>>, {opts, rest} -> {opts, rest}
      arg, {opts, rest} -> {opts, rest ++ [arg]}
    end)
    |> then(fn {opts, rest} -> {opts, List.first(rest)} end)
  end

  defp print_help do
    IO.puts("""
    Usage: sykli lock [options] [path]

    Write sykli.lock for the detected pipeline contract.

    Options:
      --json       Output as JSON (for tooling)
      --help       Show this help
    """)
  end
end
