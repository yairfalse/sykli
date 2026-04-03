defmodule Sykli.CLI.JsonResponse do
  @moduledoc """
  Shared JSON envelope for all CLI `--json` output.

  Every command that supports `--json` uses this module to ensure agents
  get a consistent shape they can parse without per-command logic.

  ## Envelope

      {"ok": true,  "version": "1", "data": { ... }, "error": null}
      {"ok": false, "version": "1", "data": null,    "error": {"code": "...", "message": "...", "hints": [...]}}
  """

  @version "1"

  @doc """
  Wrap successful data in the envelope and encode to JSON.
  """
  @spec ok(term()) :: String.t()
  def ok(data) do
    %{ok: true, version: @version, data: data, error: nil}
    |> Jason.encode!()
  end

  @doc """
  Wrap an error in the envelope and encode to JSON.

  Accepts a `Sykli.Error` struct (uses its code, message, hints) or
  a plain string (wrapped with code `"unknown"`).
  """
  @spec error(Sykli.Error.t() | String.t()) :: String.t()
  def error(%Sykli.Error{} = err) do
    %{
      ok: false,
      version: @version,
      data: nil,
      error: %{
        code: err.code,
        message: err.message,
        hints: err.hints
      }
    }
    |> Jason.encode!()
  end

  def error(message) when is_binary(message) do
    %{
      ok: false,
      version: @version,
      data: nil,
      error: %{code: "unknown", message: message, hints: []}
    }
    |> Jason.encode!()
  end
end
