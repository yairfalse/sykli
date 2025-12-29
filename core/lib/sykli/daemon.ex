defmodule Sykli.Daemon do
  @moduledoc """
  Daemon mode for SYKLI - long-running BEAM node that joins the mesh.

  The daemon enables distributed CI by keeping a BEAM node alive that can:
  - Auto-discover other SYKLI daemons via libcluster
  - Receive and execute tasks from other nodes
  - Report status to the coordinator

  ## Usage

      # Start daemon (backgrounds by default)
      sykli daemon start

      # Start in foreground (for debugging)
      sykli daemon start --foreground

      # Check status
      sykli daemon status

      # Stop daemon
      sykli daemon stop

  ## How it works

  1. Starts a named BEAM node (e.g., `sykli_abc123@hostname`)
  2. Joins the cluster via libcluster gossip
  3. Registers with the Coordinator (if one exists)
  4. Waits for tasks from other nodes via `Sykli.Mesh`
  5. Writes PID file to `~/.sykli/daemon.pid`

  ## Configuration

  Environment variables:
  - `SYKLI_COOKIE` - Erlang distribution cookie (default: auto-generated)
  - `SYKLI_PORT` - EPMD port range start (default: 4369)
  """

  require Logger

  @default_dir Path.expand("~/.sykli")
  @pid_filename "daemon.pid"

  # Timeouts and retry configuration
  @daemon_startup_delay_ms 500
  @shutdown_max_retries 50
  @shutdown_retry_interval_ms 100

  # ---------------------------------------------------------------------------
  # NODE NAMING
  # ---------------------------------------------------------------------------

  @doc """
  Generate a unique node name for this daemon.

  ## Options

    * `:prefix` - Name prefix (default: "sykli")

  ## Examples

      Daemon.node_name()
      # => :"sykli_a1b2c3@mymachine.local"

      Daemon.node_name(prefix: "worker")
      # => :"worker_a1b2c3@mymachine.local"
  """
  @spec node_name(keyword()) :: atom()
  def node_name(opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "sykli")
    suffix = :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
    hostname = get_hostname()

    :"#{prefix}_#{suffix}@#{hostname}"
  end

  @doc """
  Get the hostname for node naming.

  Tries to get a routable hostname, falls back to localhost.
  """
  @spec get_hostname() :: String.t()
  def get_hostname do
    case :inet.gethostname() do
      {:ok, hostname} ->
        hostname
        |> to_string()
        |> sanitize_hostname()

      _ ->
        "localhost"
    end
  end

  defp sanitize_hostname(hostname) do
    hostname
    |> String.replace(~r/[^a-zA-Z0-9.\-]/, "-")
    |> String.trim("-")
    |> case do
      "" -> "localhost"
      h -> h
    end
  end

  # ---------------------------------------------------------------------------
  # PID FILE MANAGEMENT
  # ---------------------------------------------------------------------------

  @doc """
  Returns the path to the daemon PID file.
  """
  @spec pid_file() :: String.t()
  def pid_file do
    Path.join(daemon_dir(), @pid_filename)
  end

  @doc """
  Returns the daemon directory.
  """
  @spec daemon_dir() :: String.t()
  def daemon_dir do
    Application.get_env(:sykli, :daemon_dir, @default_dir)
  end

  @doc """
  Write current process PID to the pid file.
  """
  @spec write_pid_file() :: :ok | {:error, term()}
  def write_pid_file do
    path = pid_file()
    dir = Path.dirname(path)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, "#{System.pid()}") do
      :ok
    end
  end

  @doc """
  Remove the pid file.
  """
  @spec remove_pid_file() :: :ok
  def remove_pid_file do
    case File.rm(pid_file()) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _} -> :ok
    end
  end

  @doc """
  Check if daemon is currently running.
  """
  @spec running?() :: boolean()
  def running? do
    case read_pid() do
      nil -> false
      pid -> process_alive?(pid)
    end
  end

  defp read_pid do
    case File.read(pid_file()) do
      {:ok, content} ->
        content |> String.trim() |> String.to_integer()

      {:error, _} ->
        nil
    end
  rescue
    _ -> nil
  end

  defp process_alive?(pid) when is_integer(pid) and pid > 0 do
    case platform() do
      :macos -> check_process_macos(pid)
      :linux -> check_process_linux(pid)
      _ -> check_process_generic(pid)
    end
  end

  defp process_alive?(_pid), do: false

  defp check_process_macos(pid) do
    pid_str = Integer.to_string(pid)

    case System.cmd("ps", ["-p", pid_str], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp check_process_linux(pid) do
    File.exists?("/proc/#{pid}")
  end

  defp check_process_generic(pid) do
    pid_str = Integer.to_string(pid)

    case System.cmd("kill", ["-0", pid_str], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  # ---------------------------------------------------------------------------
  # STATUS
  # ---------------------------------------------------------------------------

  @doc """
  Get daemon status.

  Returns `{:running, info}` or `{:stopped, info}`.
  """
  @spec status() :: {:running, map()} | {:stopped, map()}
  def status do
    case read_pid() do
      nil ->
        {:stopped, %{reason: :no_pid_file}}

      pid ->
        if process_alive?(pid) do
          {:running,
           %{
             pid: pid,
             pid_file: pid_file(),
             # Node info would come from the actual running daemon
             node: nil
           }}
        else
          {:stopped, %{reason: :process_dead, stale_pid: pid}}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # CONFIGURATION
  # ---------------------------------------------------------------------------

  @doc """
  Get daemon configuration.
  """
  @spec config() :: map()
  def config do
    %{
      port: parse_port(System.get_env("SYKLI_PORT")),
      cookie: System.get_env("SYKLI_COOKIE") || generate_cookie(),
      cluster_strategy: :gossip
    }
  end

  defp parse_port(nil), do: 4369

  defp parse_port(value) do
    case Integer.parse(value) do
      {port, ""} when port > 0 and port <= 65535 -> port
      _ -> 4369
    end
  end

  defp generate_cookie do
    :crypto.strong_rand_bytes(16) |> Base.encode64()
  end

  # ---------------------------------------------------------------------------
  # PLATFORM
  # ---------------------------------------------------------------------------

  @doc """
  Detect the current platform.
  """
  @spec platform() :: :macos | :linux | :other
  def platform do
    case :os.type() do
      {:unix, :darwin} -> :macos
      {:unix, :linux} -> :linux
      _ -> :other
    end
  end

  # ---------------------------------------------------------------------------
  # START / STOP
  # ---------------------------------------------------------------------------

  @doc """
  Start the daemon.

  ## Options

    * `:foreground` - Run in foreground instead of backgrounding (default: false)
    * `:dry_run` - Validate but don't actually start (default: false)
    * `:name` - Custom node name (default: auto-generated)

  ## Returns

    * `{:ok, pid}` - Daemon started successfully
    * `{:error, :already_running}` - Daemon is already running
    * `{:error, reason}` - Failed to start
  """
  @spec start(keyword()) :: {:ok, pid()} | {:error, term()}
  def start(opts \\ []) do
    if running?() do
      {:error, :already_running}
    else
      do_start(opts)
    end
  end

  defp do_start(opts) do
    foreground = Keyword.get(opts, :foreground, false)
    dry_run = Keyword.get(opts, :dry_run, false)

    if dry_run do
      {:ok, self()}
    else
      if foreground do
        start_foreground(opts)
      else
        start_background(opts)
      end
    end
  end

  defp start_foreground(opts) do
    node_name = Keyword.get(opts, :name) || node_name()
    config = config()

    # Start distribution if not already started
    case start_distribution(node_name, config.cookie) do
      :ok ->
        write_pid_file()
        Logger.info("[Sykli.Daemon] Started as #{node_name}")

        # Start the application supervision tree
        start_daemon_services()

        {:ok, self()}

      {:error, reason} ->
        {:error, {:distribution_failed, reason}}
    end
  end

  defp start_background(_opts) do
    # Get the path to the sykli executable
    sykli_path = System.find_executable("sykli") || find_escript()

    if sykli_path do
      # Spawn a detached process
      port =
        Port.open({:spawn_executable, sykli_path}, [
          :binary,
          :exit_status,
          args: ["daemon", "start", "--foreground"],
          # Detach from terminal
          env: [{~c"SYKLI_DAEMON", ~c"1"}]
        ])

      # Give daemon time to initialize and write PID file
      Process.sleep(@daemon_startup_delay_ms)

      if running?() do
        close_port_safely(port)
        {:ok, read_pid()}
      else
        {:error, :failed_to_start}
      end
    else
      {:error, :executable_not_found}
    end
  rescue
    e -> {:error, {:spawn_failed, e}}
  end

  defp find_escript do
    # Try to find the escript in common locations
    paths = [
      Path.join(File.cwd!(), "sykli"),
      Path.join([File.cwd!(), "core", "sykli"]),
      Path.expand("~/.mix/escripts/sykli")
    ]

    Enum.find(paths, &File.exists?/1)
  end

  defp start_distribution(node_name, cookie) do
    case Node.start(node_name, :longnames) do
      {:ok, _} ->
        Node.set_cookie(String.to_atom(cookie))
        :ok

      {:error, {:already_started, _}} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_daemon_services do
    # Start cluster discovery
    case Sykli.Cluster.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      _ -> :ok
    end

    # Start coordinator (if we're the coordinator node)
    # For now, every daemon can receive tasks
    case Sykli.Coordinator.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      _ -> :ok
    end

    :ok
  end

  @doc """
  Stop the daemon.

  ## Returns

    * `:ok` - Daemon stopped successfully
    * `{:error, :not_running}` - Daemon is not running
    * `{:error, reason}` - Failed to stop
  """
  @spec stop() :: :ok | {:error, term()}
  def stop do
    case read_pid() do
      nil ->
        {:error, :not_running}

      pid ->
        if process_alive?(pid) do
          do_stop(pid)
        else
          # Clean up stale pid file
          remove_pid_file()
          {:error, :not_running}
        end
    end
  end

  defp do_stop(pid) when is_integer(pid) and pid > 0 do
    pid_str = Integer.to_string(pid)

    # Send SIGTERM
    case System.cmd("kill", [pid_str], stderr_to_stdout: true) do
      {_, 0} ->
        # Wait for process to die (50 retries * 100ms = 5 seconds max)
        wait_for_death(pid_str, @shutdown_max_retries)

      {error, _} ->
        {:error, {:kill_failed, error}}
    end
  end

  defp do_stop(_pid), do: {:error, :invalid_pid}

  defp wait_for_death(pid_str, 0) do
    # Force kill if still alive after timeout
    System.cmd("kill", ["-9", pid_str], stderr_to_stdout: true)
    remove_pid_file()
    :ok
  end

  defp wait_for_death(pid_str, retries) do
    pid = String.to_integer(pid_str)

    if process_alive?(pid) do
      Process.sleep(@shutdown_retry_interval_ms)
      wait_for_death(pid_str, retries - 1)
    else
      remove_pid_file()
      :ok
    end
  end

  defp close_port_safely(port) do
    if Port.info(port) != nil do
      Port.close(port)
    end
  rescue
    _ -> :ok
  end
end
