defmodule Sykli.Runtime.Fake do
  @moduledoc """
  Deterministic in-memory `Sykli.Runtime.Behaviour` implementation for tests.

  Used as the default runtime in `:test` env (RC.4a) and as the seed for
  mesh simulation tests later. No external binaries, no processes, no ETS,
  no process dictionary — state lives in the test via a recorder pid.

  ## Recording calls

  If `opts[:fake_recorder]` is a pid, callbacks that accept `opts`
  (`run/4` and `start_service/4`) send a message of the form
  `{:sykli_runtime_fake, {op, args...}}` to it. Tests use
  `assert_receive` to inspect what the runtime saw:

      Sykli.Runtime.Fake.run("echo hi", "alpine", [], fake_recorder: self())
      assert_receive {:sykli_runtime_fake, {:run, "echo hi", "alpine", [], _opts}}

  ## Scripting responses

  `opts[:fake_script]` is a map keyed by operation atom for the callbacks
  in this fake runtime that accept `opts` and consult scripted responses:
  currently `run/4` and `start_service/4`. When one of those keys is
  present the mapped value is returned verbatim, letting tests exercise
  error paths:

      Sykli.Runtime.Fake.run("irrelevant", nil, [],
        fake_script: %{run: {:error, :boom}}
      )
      #=> {:error, :boom}

  Calls are still recorded when scripted.

  ## Timeout modeling

  When no `:run` script is provided, the Fake models only bare `sleep N`
  commands, where `N` is an integer or fractional second value. If that
  modeled duration exceeds `opts[:timeout_ms]`, `run/4` returns
  `{:error, :timeout}` without actually sleeping. Compound shell commands
  and absolute sleep paths are not parsed.

  ## Determinism

  No wall clock, no global RNG. Identifiers derive from `:erlang.phash2/1`
  of their inputs — stable across runs. Given an identical opts and call
  sequence, the Fake produces byte-identical output and byte-identical
  recorder messages.
  """

  @behaviour Sykli.Runtime.Behaviour

  @impl true
  def name, do: "fake"

  @impl true
  def available?, do: {:ok, %{type: "fake"}}

  @impl true
  def network_isolation?, do: true

  @impl true
  def run(command, image, mounts, opts) do
    record(opts, {:run, command, image, mounts, opts})
    scripted(opts, :run, default_run(command, opts))
  end

  @impl true
  def start_service(name, image, network, opts) do
    record(opts, {:start_service, name, image, network, opts})
    scripted(opts, :start_service, {:ok, deterministic_id("svc", {name, image, network})})
  end

  @impl true
  def stop_service(container_id) do
    _ = container_id
    :ok
  end

  @impl true
  def create_network(name), do: {:ok, deterministic_id("net", name)}

  @impl true
  def remove_network(_network_id), do: :ok

  # ─── internals ──────────────────────────────────────────────────────────

  defp record(opts, call) do
    case Keyword.get(opts, :fake_recorder) do
      nil -> :ok
      pid when is_pid(pid) -> send(pid, {:sykli_runtime_fake, call})
    end
  end

  defp scripted(opts, op, default) do
    opts
    |> Keyword.get(:fake_script, %{})
    |> Map.get(op, default)
  end

  defp default_run(command, opts) do
    case fake_sleep_ms(command) do
      sleep_ms when is_integer(sleep_ms) ->
        timeout_ms = Keyword.get(opts, :timeout_ms)

        if is_integer(timeout_ms) and sleep_ms > timeout_ms do
          {:error, :timeout}
        else
          {:ok, 0, 0, ""}
        end

      nil ->
        {:ok, 0, 0, ""}
    end
  end

  defp fake_sleep_ms(command) when is_binary(command) do
    case String.split(command) do
      ["sleep", duration] -> parse_duration_ms(duration)
      _other -> nil
    end
  end

  defp fake_sleep_ms(_command), do: nil

  defp parse_duration_ms(duration) do
    case Float.parse(duration) do
      {seconds, ""} when seconds >= 0 ->
        round(seconds * 1000)

      _other ->
        nil
    end
  end

  defp deterministic_id(prefix, seed) do
    hash = seed |> :erlang.phash2() |> Integer.to_string(16) |> String.downcase()
    "fake-#{prefix}-#{hash}"
  end
end
