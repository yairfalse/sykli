defmodule Sykli.CLI.Contract do
  @moduledoc """
  `sykli contract` command.
  """

  alias Sykli.CLI.JsonResponse
  alias Sykli.ContractDiff
  alias Sykli.ContractLock
  alias Sykli.Error
  alias Sykli.Error.Formatter

  def run(args, runtime_opts \\ []) do
    case parse(args) do
      {:help, _opts} ->
        print_help()
        0

      {:render, path, opts} ->
        render(path || ".", opts, runtime_opts)

      {:diff, path, lock_path, opts} ->
        diff(path || ".", lock_path, opts, runtime_opts)
    end
  end

  defp render(path, opts, runtime_opts) do
    json? = Keyword.get(opts, :json, false)

    case current(path, runtime_opts) do
      {:ok, current} ->
        if json? do
          IO.puts(JsonResponse.ok(current.contract))
        else
          IO.puts(render_contract(current.contract, current.hash))
        end

        0

      {:error, reason} ->
        output_error(reason, json?)
    end
  end

  defp diff(path, lock_arg, opts, runtime_opts) do
    json? = Keyword.get(opts, :json, false)

    with {:ok, current} <- current(path, runtime_opts),
         {:ok, lock_path} <- diff_lock_path(path, lock_arg, runtime_opts),
         {:ok, lock} <- ContractLock.read(lock_path) do
      changes = ContractDiff.classify(lock["contract"], current.contract)
      weakening? = Enum.any?(changes, &(&1.direction == :weakening))

      if json? do
        IO.puts(
          JsonResponse.ok(%{
            changes: Enum.map(changes, &stringify_direction/1),
            weakening: weakening?,
            from_hash: lock["contract_hash"],
            to_hash: current.hash
          })
        )
      else
        IO.puts(render_changes(changes, lock["contract_hash"], current.hash, weakening?))
      end

      if weakening?, do: 1, else: 0
    else
      {:error, reason} -> output_error(reason, json?)
    end
  end

  defp current(path, runtime_opts) do
    with {:ok, sdk} <- detector(runtime_opts).find(path) do
      ContractLock.double_emit(fn -> emit(runtime_opts, sdk) end)
    end
  end

  defp diff_lock_path(path, nil, runtime_opts) do
    with {:ok, {sdk_file, _runner}} <- detector(runtime_opts).find(path) do
      lock_path = ContractLock.lock_path_for_sdk(sdk_file)

      if File.exists?(lock_path) do
        {:ok, lock_path}
      else
        {:error,
         %Error{
           code: "contract.lock_corrupt",
           type: :validation,
           message: "sykli.lock was not found",
           step: :validate,
           hints: ["run `sykli lock` before diffing the contract"]
         }}
      end
    end
  end

  defp diff_lock_path(_path, lock_path, _runtime_opts), do: {:ok, lock_path}

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

  defp render_contract(contract, hash) do
    tasks = contract["tasks"] || []

    [
      "Contract #{hash}\n",
      "schema #{contract["version"] || "-"}\n",
      Enum.map(tasks, &render_task/1)
    ]
    |> IO.iodata_to_binary()
  end

  defp render_task(task) do
    [
      "\n",
      task["name"] || "-",
      "  ",
      task["task_type"] || task["kind"] || "task",
      "\n",
      render_line("deps", Enum.join(task["depends_on"] || [], ", ")),
      render_line("command", task["command"]),
      render_line("condition", task["when"] || task["condition"]),
      render_list("criteria", task["success_criteria"]),
      render_list("evidence", task["evidence_required"]),
      render_list("capabilities", task["requires"]),
      render_gate(task)
    ]
  end

  defp render_line(_label, nil), do: []
  defp render_line(_label, ""), do: []
  defp render_line(label, value), do: ["  ", label, ": ", to_string(value), "\n"]

  defp render_list(_label, nil), do: []
  defp render_list(_label, []), do: []

  defp render_list(label, values) do
    ["  ", label, ":\n", Enum.map(values, fn value -> ["    - ", inspect(value), "\n"] end)]
  end

  defp render_gate(%{"gate" => gate}) when not is_nil(gate),
    do: render_line("gate", inspect(gate))

  defp render_gate(%{"kind" => "review"}), do: "  gate: review\n"
  defp render_gate(_task), do: []

  defp render_changes([], from_hash, to_hash, _weakening?) do
    "Contract diff #{from_hash} -> #{to_hash}\nNo contract changes\nVerdict: no weakening\n"
  end

  defp render_changes(changes, from_hash, to_hash, weakening?) do
    groups = [:weakening, :strengthening, :neutral]

    body =
      groups
      |> Enum.flat_map(fn direction ->
        selected = Enum.filter(changes, &(&1.direction == direction))

        if selected == [] do
          []
        else
          [
            "\n",
            String.capitalize(Atom.to_string(direction)),
            "\n",
            Enum.map(selected, fn change ->
              ["  - ", change.task || "-", ": ", change.detail, field_suffix(change.field), "\n"]
            end)
          ]
        end
      end)

    verdict = if weakening?, do: "weakening present", else: "no weakening"

    IO.iodata_to_binary([
      "Contract diff #{from_hash} -> #{to_hash}\n",
      body,
      "Verdict: ",
      verdict,
      "\n"
    ])
  end

  defp field_suffix(nil), do: ""
  defp field_suffix(field), do: " (#{field})"

  defp stringify_direction(change), do: %{change | direction: Atom.to_string(change.direction)}

  defp parse(args) do
    {opts, rest} =
      Enum.reduce(args, {[], []}, fn
        "--json", {opts, rest} -> {[json: true] ++ opts, rest}
        "--help", {opts, rest} -> {[help: true] ++ opts, rest}
        "-h", {opts, rest} -> {[help: true] ++ opts, rest}
        "--diff", {opts, rest} -> {[diff: true] ++ opts, rest}
        arg, {opts, rest} -> {opts, rest ++ [arg]}
      end)

    cond do
      Keyword.get(opts, :help, false) ->
        {:help, opts}

      Keyword.get(opts, :diff, false) ->
        {path, lock_path} = diff_args(rest)
        {:diff, path, lock_path, opts}

      true ->
        {:render, List.first(rest), opts}
    end
  end

  defp diff_args([]), do: {".", nil}
  defp diff_args([one]), do: {".", one}
  defp diff_args([path, lock_path | _]), do: {path, lock_path}

  defp print_help do
    IO.puts("""
    Usage: sykli contract [options] [path]
           sykli contract --diff [lockfile]

    Render or diff the emitted contract.

    Options:
      --diff       Compare current emission against sykli.lock or a lockfile
      --json       Output as JSON (for tooling)
      --help       Show this help
    """)
  end
end
