defmodule Sykli.GitHub.WorkspaceJanitor do
  @moduledoc "Cleans GitHub source workspaces when their owner process exits."

  require Logger

  @cleanup_timeout_ms 5_000

  @spec start(pid(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start(owner, path, opts \\ []) when is_pid(owner) and is_binary(path) do
    Task.start(fn ->
      ref = Process.monitor(owner)
      loop(owner, ref, path, opts)
    end)
  end

  @spec cleanup(pid()) :: :ok | {:error, :timeout}
  def cleanup(pid) when is_pid(pid) do
    ref = make_ref()
    send(pid, {:cleanup, self(), ref})

    receive do
      {^ref, :ok} -> :ok
    after
      @cleanup_timeout_ms ->
        Logger.warning("[GitHub WorkspaceJanitor] cleanup timed out",
          janitor: inspect(pid),
          timeout_ms: @cleanup_timeout_ms
        )

        {:error, :timeout}
    end
  end

  def cleanup(_pid), do: :ok

  defp loop(owner, monitor_ref, path, opts) do
    receive do
      {:cleanup, caller, reply_ref} ->
        Process.demonitor(monitor_ref, [:flush])
        do_cleanup(path, opts)
        send(caller, {reply_ref, :ok})

      {:DOWN, ^monitor_ref, :process, ^owner, _reason} ->
        do_cleanup(path, opts)
    end
  end

  defp do_cleanup(path, opts) do
    Sykli.GitHub.Source.cleanup(path, opts)
  rescue
    error ->
      Logger.warning("[GitHub WorkspaceJanitor] cleanup failed", error: inspect(error))
      :ok
  catch
    :exit, reason ->
      Logger.warning("[GitHub WorkspaceJanitor] cleanup exited", reason: inspect(reason))
      :ok
  end
end
