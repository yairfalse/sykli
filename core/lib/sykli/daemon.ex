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

  # Node roles
  @type role :: :full | :worker | :coordinator

  @role_prefixes %{
    full: "sykli",
    worker: "worker",
    coordinator: "coordinator"
  }

  # ---------------------------------------------------------------------------
  # NODE NAMING
  # ---------------------------------------------------------------------------

  @doc """
  Generate a unique node name for this daemon.

  ## Options

    * `:role` - Node role: `:full`, `:worker`, or `:coordinator` (default: `:full`)
    * `:prefix` - Custom name prefix (overrides role-based prefix)

  ## Examples

      Daemon.node_name()
      # => :"sykli_a1b2c3@mymachine.local"

      Daemon.node_name(role: :worker)
      # => :"worker_a1b2c3@mymachine.local"

      Daemon.node_name(role: :coordinator)
      # => :"coordinator_a1b2c3@mymachine.local"
  """
  @spec node_name(keyword()) :: atom()
  def node_name(opts \\ []) do
    role = Keyword.get(opts, :role, :full)
    prefix = Keyword.get(opts, :prefix) || Map.get(@role_prefixes, role, "sykli")
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
  # ROLE DETECTION
  # ---------------------------------------------------------------------------

  @doc """
  Get the role of a node from its name.

  ## Examples

      Daemon.node_role(:"sykli_abc123@host")
      # => :full

      Daemon.node_role(:"worker_abc123@host")
      # => :worker

      Daemon.node_role(:"coordinator_abc123@host")
      # => :coordinator
  """
  @spec node_role(node()) :: role()
  def node_role(node_name) do
    name_str = to_string(node_name)

    cond do
      String.starts_with?(name_str, "coordinator_") -> :coordinator
      String.starts_with?(name_str, "worker_") -> :worker
      true -> :full
    end
  end

  @doc """
  Check if a node is a coordinator.
  """
  @spec coordinator?(node()) :: boolean()
  def coordinator?(node_name) do
    node_role(node_name) == :coordinator
  end

  @doc """
  Check if a node is a worker-only node.
  """
  @spec worker?(node()) :: boolean()
  def worker?(node_name) do
    node_role(node_name) == :worker
  end

  @doc """
  Check if a node can execute tasks.

  Workers and full nodes can execute. Coordinators cannot.
  """
  @spec can_execute?(node()) :: boolean()
  def can_execute?(node_name) do
    node_role(node_name) in [:full, :worker]
  end

  @doc """
  Check if a node can coordinate (run dashboard, aggregate events).

  Coordinators and full nodes can coordinate. Workers cannot.
  """
  @spec can_coordinate?(node()) :: boolean()
  def can_coordinate?(node_name) do
    node_role(node_name) in [:full, :coordinator]
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

      {:error, :enoent} ->
        # PID file doesn't exist - normal when daemon not running
        nil

      {:error, reason} ->
        Logger.warning("[Sykli.Daemon] Failed to read PID file: #{inspect(reason)}")
        nil
    end
  rescue
    e ->
      Logger.warning("[Sykli.Daemon] Error parsing PID file: #{inspect(e)}")
      nil
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
    * `:role` - Node role (default: `:full`):
      - `:full` - Can execute tasks AND coordinate (default, symmetric mesh)
      - `:worker` - Can only execute tasks, forwards events to coordinator
      - `:coordinator` - Can only coordinate, does not execute tasks

  ## Returns

    * `{:ok, pid}` - Daemon started successfully
    * `{:error, :already_running}` - Daemon is already running
    * `{:error, reason}` - Failed to start

  ## Examples

      # Start a full node (can do everything)
      Daemon.start()

      # Start a worker-only node
      Daemon.start(role: :worker)

      # Start a coordinator-only node
      Daemon.start(role: :coordinator)
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

  # Starts the daemon in the current process (foreground mode).
  # This initializes Erlang distribution, writes the PID file, and starts
  # cluster/coordinator services. Used for debugging or when running under
  # a process supervisor.
  defp start_foreground(opts) do
    role = Keyword.get(opts, :role, :full)
    node_name = Keyword.get(opts, :name) || node_name(role: role)
    config = config()

    # Start distribution if not already started
    case start_distribution(node_name, config.cookie) do
      :ok ->
        write_pid_file()
        Logger.info("[Sykli.Daemon] Started as #{node_name} (role: #{role})")

        # Start the application supervision tree based on role
        start_daemon_services(role)

        {:ok, self()}

      {:error, reason} ->
        {:error, {:distribution_failed, reason}}
    end
  end

  defp start_background(opts) do
    # Get the path to the sykli executable
    sykli_path = System.find_executable("sykli") || find_escript()
    role = Keyword.get(opts, :role, :full)

    if sykli_path do
      # Build args with role
      args = ["daemon", "start", "--foreground", "--role", to_string(role)]

      # Spawn a detached process
      port =
        Port.open({:spawn_executable, sykli_path}, [
          :binary,
          :exit_status,
          args: args,
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
        # Cookie conversion is safe here - cookies are only set once per daemon
        # start, either from env var or generated. Not a continuous atom leak.
        cookie_atom = if is_atom(cookie), do: cookie, else: String.to_atom(cookie)
        Node.set_cookie(cookie_atom)
        :ok

      {:error, {:already_started, _}} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_daemon_services(role) do
    # Cluster discovery is always needed for mesh networking
    start_service(Sykli.Cluster, "Cluster")

    # Start role-specific services
    case role do
      :worker ->
        # Workers only execute tasks - no Coordinator service
        # The Reporter forwards events to remote coordinator
        Logger.info("[Sykli.Daemon] Worker mode - will execute tasks only")

      :coordinator ->
        # Coordinators run the Coordinator service but don't execute tasks
        start_service(Sykli.Coordinator, "Coordinator")
        Logger.info("[Sykli.Daemon] Coordinator mode - will not execute tasks")

      :full ->
        # Full nodes do everything
        start_service(Sykli.Coordinator, "Coordinator")
        Logger.info("[Sykli.Daemon] Full mode - can execute and coordinate")
    end

    :ok
  end

  defp start_service(module, name) do
    case module.start_link() do
      {:ok, _} ->
        Logger.debug("[Sykli.Daemon] Started #{name}")
        :ok

      {:error, {:already_started, _}} ->
        :ok

      {:error, reason} ->
        Logger.warning("[Sykli.Daemon] Failed to start #{name}: #{inspect(reason)}")
        :ok
    end
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
