defmodule Sykli.Runtime.Shell do
  @moduledoc """
  Shell runtime - executes commands directly via /bin/sh.

  This is the simplest runtime, running commands natively on the host.
  No containers, no isolation - just shell execution.

  ## Use Cases

  - Simple scripts that don't need isolation
  - Commands that need direct host access
  - Development/debugging without container overhead

  ## Limitations

  - No isolation from host system
  - No container image support (image parameter ignored)
  - Mounts are just path references (no real mounting)

  ## Example

      {:ok, info} = Sykli.Runtime.Shell.available?()
      #=> {:ok, %{shell: "/bin/sh"}}

      {:ok, 0, lines, output} = Sykli.Runtime.Shell.run(
        "echo hello",
        nil,
        [],
        workdir: "/tmp"
      )
  """

  @behaviour Sykli.Runtime.Behaviour

  # ─────────────────────────────────────────────────────────────────────────────
  # IDENTITY
  # ─────────────────────────────────────────────────────────────────────────────

  @impl true
  def name, do: "shell"

  @impl true
  def available? do
    case System.find_executable("sh") do
      nil -> {:error, :shell_not_found}
      path -> {:ok, %{shell: path}}
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # EXECUTION
  # ─────────────────────────────────────────────────────────────────────────────

  @impl true
  def run(command, _image, _mounts, opts) do
    workdir = Keyword.get(opts, :workdir, ".")
    timeout_ms = Keyword.get(opts, :timeout_ms, 300_000)
    env = Keyword.get(opts, :env, %{})

    # Convert env map to list of tuples for Port
    env_list = Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    port = Port.open(
      {:spawn_executable, "/bin/sh"},
      [:binary, :exit_status, :stderr_to_stdout,
       args: ["-c", command],
       cd: workdir,
       env: env_list]
    )

    try do
      stream_output(port, timeout_ms)
    after
      safe_port_close(port)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # STREAMING
  # ─────────────────────────────────────────────────────────────────────────────

  defp stream_output(port, timeout_ms), do: stream_output(port, timeout_ms, 0, [])

  defp stream_output(port, timeout_ms, line_count, output_acc) do
    receive do
      {^port, {:data, data}} ->
        IO.write("  #{IO.ANSI.faint()}#{data}#{IO.ANSI.reset()}")
        new_lines = data |> :binary.matches("\n") |> length()
        stream_output(port, timeout_ms, line_count + new_lines, [data | output_acc])

      {^port, {:exit_status, status}} ->
        full_output = output_acc |> Enum.reverse() |> Enum.join()
        output = String.slice(full_output, -min(String.length(full_output), 4000)..-1//1)
        {:ok, status, line_count, output}
    after
      timeout_ms ->
        safe_port_close(port)
        {:error, :timeout}
    end
  end

  defp safe_port_close(port) do
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end
  end
end
