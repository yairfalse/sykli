defmodule Sykli.CLI.Audit do
  @moduledoc false

  alias Sykli.CLI.JsonResponse
  alias Sykli.Services.Audit

  def run(args, opts \\ []) do
    {json?, rest} = parse_args(args)
    path = Keyword.get(opts, :path, ".")

    case rest do
      [run_id] ->
        run_audit(path, run_id, json?)

      [] ->
        emit_error(json?, audit_error("audit.run_not_found", "run id is required"))
        1

      _ ->
        emit_error(json?, audit_error("audit.invalid_args", "usage: sykli audit <run-id>"))
        1
    end
  end

  defp parse_args(args) do
    json? = Enum.member?(args, "--json")
    rest = Enum.reject(args, &(&1 == "--json"))
    {json?, rest}
  end

  defp run_audit(path, run_id, json?) do
    case Audit.audit(path, run_id) do
      {:ok, result} ->
        emit_result(json?, result)
        if result.verdict == "pass", do: 0, else: 1

      {:error, :not_found} ->
        emit_error(json?, audit_error("audit.run_not_found", "run not found: #{run_id}"))
        1

      {:error, :corrupt} ->
        emit_error(
          json?,
          audit_error(
            "audit.history_corrupt",
            "run manifest for #{run_id} is corrupt and cannot be audited"
          )
        )

        1
    end
  end

  defp emit_result(true, result), do: IO.puts(JsonResponse.ok(result))

  defp emit_result(false, result) do
    IO.puts("audit #{result.run_id}: #{result.verdict}")

    Enum.each(result.findings, fn f ->
      IO.puts("  #{f["status"]} #{f["check"]}: #{f["message"]}")

      f
      |> Map.get("details", %{})
      |> Enum.sort()
      |> Enum.each(fn {key, value} -> IO.puts("    #{key}: #{value}") end)
    end)
  end

  defp emit_error(true, error), do: IO.puts(JsonResponse.error(error))
  defp emit_error(false, error), do: IO.puts(:stderr, Exception.message(error))

  defp audit_error(code, message) do
    %Sykli.Error{code: code, type: :validation, message: message, hints: [], notes: []}
  end
end
