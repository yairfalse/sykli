defmodule Sykli.DaemonTest do
  use ExUnit.Case, async: false

  alias Sykli.Daemon

  @test_pid_dir Path.expand("/tmp/sykli_daemon_test_#{System.unique_integer([:positive])}")

  setup do
    # Use test-specific directory
    File.mkdir_p!(@test_pid_dir)
    Application.put_env(:sykli, :daemon_dir, @test_pid_dir)

    on_exit(fn ->
      File.rm_rf!(@test_pid_dir)
      Application.delete_env(:sykli, :daemon_dir)
    end)

    :ok
  end

  describe "node_name/1" do
    test "generates valid node name with hostname" do
      name = Daemon.node_name()

      assert is_atom(name)
      name_str = Atom.to_string(name)
      assert String.starts_with?(name_str, "sykli_")
      assert String.contains?(name_str, "@")
    end

    test "generates unique names using random suffix" do
      # Generate multiple names and verify they differ
      # The 3-byte random suffix provides enough entropy
      names = for _ <- 1..10, do: Daemon.node_name()

      # All should be atoms with correct format
      assert Enum.all?(names, &is_atom/1)

      # Should have unique values (duplicates extremely unlikely with 3 random bytes)
      unique_names = Enum.uniq(names)
      assert length(unique_names) == length(names)
    end

    test "allows custom prefix" do
      name = Daemon.node_name(prefix: "worker")

      name_str = Atom.to_string(name)
      assert String.starts_with?(name_str, "worker_")
    end
  end

  describe "pid_file/0" do
    test "returns path in daemon directory" do
      path = Daemon.pid_file()

      assert String.ends_with?(path, "daemon.pid")
      assert String.starts_with?(path, @test_pid_dir)
    end
  end

  describe "running?/0" do
    test "returns false when no pid file exists" do
      refute Daemon.running?()
    end

    test "returns false when pid file contains dead process" do
      # Write a PID that definitely doesn't exist
      File.write!(Daemon.pid_file(), "999999999")

      refute Daemon.running?()
    end

    test "returns true when pid file contains live process" do
      # Write our own PID (we're definitely alive)
      File.write!(Daemon.pid_file(), "#{System.pid()}")

      assert Daemon.running?()
    end
  end

  describe "status/0" do
    test "returns :stopped when not running" do
      assert {:stopped, _info} = Daemon.status()
    end

    test "returns :running with info when running" do
      # Simulate running daemon by writing our PID
      File.write!(Daemon.pid_file(), "#{System.pid()}")

      assert {:running, info} = Daemon.status()
      # System.pid() returns a string, we store/return as integer
      assert info.pid == String.to_integer(System.pid())
    end
  end

  describe "write_pid_file/0" do
    test "writes current system pid" do
      :ok = Daemon.write_pid_file()

      content = File.read!(Daemon.pid_file())
      assert content == "#{System.pid()}"
    end

    test "creates directory if needed" do
      nested_dir = Path.join(@test_pid_dir, "nested/deep")
      Application.put_env(:sykli, :daemon_dir, nested_dir)

      :ok = Daemon.write_pid_file()

      assert File.exists?(Path.join(nested_dir, "daemon.pid"))
    end
  end

  describe "remove_pid_file/0" do
    test "removes the pid file" do
      File.write!(Daemon.pid_file(), "12345")
      assert File.exists?(Daemon.pid_file())

      :ok = Daemon.remove_pid_file()

      refute File.exists?(Daemon.pid_file())
    end

    test "succeeds even if file doesn't exist" do
      refute File.exists?(Daemon.pid_file())

      assert :ok = Daemon.remove_pid_file()
    end
  end

  describe "get_hostname/0" do
    test "returns a string" do
      hostname = Daemon.get_hostname()

      assert is_binary(hostname)
      assert String.length(hostname) > 0
    end

    test "returns valid hostname format" do
      hostname = Daemon.get_hostname()

      # Should be a valid hostname (alphanumeric, dots, hyphens)
      assert Regex.match?(~r/^[a-zA-Z0-9][a-zA-Z0-9.\-]*$/, hostname)
    end
  end

  describe "config/0" do
    test "returns default configuration" do
      config = Daemon.config()

      assert is_map(config)
      assert Map.has_key?(config, :port)
      assert Map.has_key?(config, :cookie)
    end
  end

  describe "start/1 validation" do
    test "returns error if already running" do
      # Simulate running daemon
      File.write!(Daemon.pid_file(), "#{System.pid()}")

      assert {:error, :already_running} = Daemon.start(foreground: true, dry_run: true)
    end

    test "accepts foreground option" do
      # Just verify it doesn't crash with the option
      # Actual start would block, so we use dry_run
      assert {:ok, _} = Daemon.start(foreground: true, dry_run: true)
    end
  end

  describe "stop/0" do
    test "returns error if not running" do
      assert {:error, :not_running} = Daemon.stop()
    end

    test "cleans up stale pid file when process is dead" do
      # Write a PID that doesn't exist
      File.write!(Daemon.pid_file(), "999999999")
      assert File.exists?(Daemon.pid_file())

      # Stop should detect dead process, clean up, and return not_running
      assert {:error, :not_running} = Daemon.stop()
      refute File.exists?(Daemon.pid_file())
    end
  end

  describe "platform detection" do
    test "detects current platform" do
      platform = Daemon.platform()

      assert platform in [:macos, :linux, :other]
    end
  end
end
