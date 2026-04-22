defmodule Sykli.Runtime.ResolverTest do
  @moduledoc """
  Tests for Sykli.Runtime.Resolver.

  `async: false` because these tests manipulate `Application` env,
  `System` env vars, and `:persistent_term` — all global VM state.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Sykli.Runtime.Resolver

  defmodule NotARuntime do
  end

  setup do
    original_sys_env = System.get_env("SYKLI_RUNTIME")
    original_default = Application.get_env(:sykli, :default_runtime)
    original_containerless = Application.get_env(:sykli, :containerless_runtime)
    original_probe = Application.get_env(:sykli, :runtime_probe)

    Resolver.reset()
    System.delete_env("SYKLI_RUNTIME")
    Application.put_env(:sykli, :default_runtime, nil)
    Application.delete_env(:sykli, :containerless_runtime)
    Application.put_env(:sykli, :runtime_probe, fn _ -> false end)

    on_exit(fn ->
      Resolver.reset()

      if original_sys_env,
        do: System.put_env("SYKLI_RUNTIME", original_sys_env),
        else: System.delete_env("SYKLI_RUNTIME")

      Application.put_env(:sykli, :default_runtime, original_default)

      if original_containerless,
        do: Application.put_env(:sykli, :containerless_runtime, original_containerless),
        else: Application.delete_env(:sykli, :containerless_runtime)

      if original_probe,
        do: Application.put_env(:sykli, :runtime_probe, original_probe),
        else: Application.delete_env(:sykli, :runtime_probe)
    end)

    :ok
  end

  describe "resolve/1 — priority chain" do
    test "opts[:runtime] wins over everything" do
      Application.put_env(:sykli, :default_runtime, Sykli.Runtime.Fake)
      System.put_env("SYKLI_RUNTIME", "docker")

      assert Resolver.resolve(runtime: Sykli.Runtime.Shell) == Sykli.Runtime.Shell
    end

    test "opts[:runtime] must resolve to a loaded runtime module" do
      assert_raise ArgumentError, ~r/opts\[:runtime\].*not loaded/, fn ->
        Resolver.resolve(runtime: Sykli.Runtime.Missing)
      end
    end

    test "opts[:runtime] must implement the runtime behaviour" do
      assert_raise ArgumentError, ~r/opts\[:runtime\].*does not implement/, fn ->
        Resolver.resolve(runtime: NotARuntime)
      end
    end

    test "opts[:runtime] rejects non-module values with a clear error" do
      assert_raise ArgumentError, ~r/invalid :runtime option/, fn ->
        Resolver.resolve(runtime: "shell")
      end
    end

    test "Application.get_env(:default_runtime) wins over SYKLI_RUNTIME" do
      Application.put_env(:sykli, :default_runtime, Sykli.Runtime.Fake)
      System.put_env("SYKLI_RUNTIME", "docker")

      assert Resolver.resolve([]) == Sykli.Runtime.Fake
    end

    test "Application.get_env(:default_runtime) must implement the runtime behaviour" do
      Application.put_env(:sykli, :default_runtime, NotARuntime)

      assert_raise ArgumentError, ~r/default_runtime.*does not implement/, fn ->
        Resolver.resolve([])
      end
    end

    test "SYKLI_RUNTIME=fake resolves to Fake" do
      System.put_env("SYKLI_RUNTIME", "fake")
      assert Resolver.resolve([]) == Sykli.Runtime.Fake
    end

    test "SYKLI_RUNTIME=docker resolves to Docker" do
      System.put_env("SYKLI_RUNTIME", "docker")
      assert Resolver.resolve([]) == Sykli.Runtime.Docker
    end

    test "SYKLI_RUNTIME=shell resolves to Shell" do
      System.put_env("SYKLI_RUNTIME", "shell")
      assert Resolver.resolve([]) == Sykli.Runtime.Shell
    end

    test "SYKLI_RUNTIME=podman resolves to Podman" do
      System.put_env("SYKLI_RUNTIME", "podman")
      assert Resolver.resolve([]) == Sykli.Runtime.Podman
    end

    test "SYKLI_RUNTIME accepts fully-qualified module names" do
      System.put_env("SYKLI_RUNTIME", "Elixir.Sykli.Runtime.Shell")
      assert Resolver.resolve([]) == Sykli.Runtime.Shell
    end

    test "SYKLI_RUNTIME with unknown shorthand raises with the bad value in the message" do
      System.put_env("SYKLI_RUNTIME", "nope")

      assert_raise ArgumentError, ~r/SYKLI_RUNTIME=nope/, fn ->
        Resolver.resolve([])
      end
    end

    test "SYKLI_RUNTIME with unknown fully-qualified module raises with the bad value" do
      System.put_env("SYKLI_RUNTIME", "Elixir.Does.Not.Exist")

      assert_raise ArgumentError, ~r/SYKLI_RUNTIME=Elixir\.Does\.Not\.Exist/, fn ->
        Resolver.resolve([])
      end
    end
  end

  describe "resolve/1 — auto-detect and fallback" do
    test "falls back to Shell when no runtime probes succeed" do
      # probe is stubbed to always return false in setup
      assert capture_log(fn ->
               assert Resolver.resolve([]) == Sykli.Runtime.Shell
             end) =~ "falling back to Sykli.Runtime.Shell"
    end

    test "auto-detects Docker when its probe succeeds" do
      Application.put_env(:sykli, :runtime_probe, fn
        Sykli.Runtime.Docker -> true
        _ -> false
      end)

      assert Resolver.resolve([]) == Sykli.Runtime.Docker
    end

    test "auto-detects Podman when Docker probe fails but Podman's succeeds" do
      Application.put_env(:sykli, :runtime_probe, fn
        Sykli.Runtime.Docker -> false
        Sykli.Runtime.Podman -> true
        _ -> false
      end)

      # Podman module may not exist yet; the test is still meaningful because
      # Resolver guards with Code.ensure_loaded?/1 and skips unloaded modules.
      result = Resolver.resolve([])

      if Code.ensure_loaded?(Sykli.Runtime.Podman) do
        assert result == Sykli.Runtime.Podman
      else
        assert result == Sykli.Runtime.Shell
      end
    end

    test "fallback warning is logged exactly once across multiple resolves" do
      logs =
        capture_log(fn ->
          Resolver.resolve([])
          Resolver.resolve([])
          Resolver.resolve([])
        end)

      # Exactly one occurrence of the warning
      count = logs |> String.split("falling back to Sykli.Runtime.Shell") |> length()
      assert count - 1 == 1, "expected exactly one warning, got #{count - 1}:\n#{logs}"
    end

    test "reset/0 re-enables the warning" do
      _ = capture_log(fn -> Resolver.resolve([]) end)
      Resolver.reset()
      # After reset we also need to re-stub the probe since reset clears the cache
      # but the Application env stub is still in place.
      logs = capture_log(fn -> Resolver.resolve([]) end)
      assert logs =~ "falling back to Sykli.Runtime.Shell"
    end
  end

  describe "resolve_containerless/1" do
    test "opts[:containerless_runtime] wins" do
      assert Resolver.resolve_containerless(containerless_runtime: Sykli.Runtime.Fake) ==
               Sykli.Runtime.Fake
    end

    test "Application.get_env(:containerless_runtime) is honored" do
      Application.put_env(:sykli, :containerless_runtime, Sykli.Runtime.Fake)
      assert Resolver.resolve_containerless([]) == Sykli.Runtime.Fake
    end

    test "defaults to Shell" do
      Application.delete_env(:sykli, :containerless_runtime)
      assert Resolver.resolve_containerless([]) == Sykli.Runtime.Shell
    end

    test "validates containerless runtime modules from opts" do
      assert_raise ArgumentError, ~r/containerless_runtime.*does not implement/, fn ->
        Resolver.resolve_containerless(containerless_runtime: NotARuntime)
      end
    end

    test "rejects invalid containerless runtime option types clearly" do
      assert_raise ArgumentError, ~r/invalid :containerless_runtime option/, fn ->
        Resolver.resolve_containerless(containerless_runtime: "shell")
      end
    end
  end
end
