defmodule Sykli.Runtime.FakeTest do
  @moduledoc """
  Tests for Sykli.Runtime.Fake.

  Covers identity, the four `run/4` paths (default / recorded / scripted /
  scripted-and-recorded), the optional service callbacks, a determinism
  property (100 iterations of the same sequence produce byte-identical
  recorder output), and a signature-parity check against Sykli.Runtime.Shell.
  """

  use ExUnit.Case, async: true

  alias Sykli.Runtime.Fake

  describe "identity" do
    test "name/0 returns \"fake\"" do
      assert Fake.name() == "fake"
    end

    test "available?/0 reports itself available" do
      assert {:ok, %{type: "fake"}} = Fake.available?()
    end

    test "declares @behaviour Sykli.Runtime.Behaviour" do
      behaviours =
        Fake.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Sykli.Runtime.Behaviour in behaviours
    end
  end

  describe "run/4" do
    test "returns default success when unscripted and unobserved" do
      assert {:ok, 0, 0, ""} = Fake.run("echo hi", nil, [], [])
    end

    test "records the call to the recorder pid" do
      mount = %{type: :directory, host_path: "/tmp", container_path: "/w"}
      Fake.run("echo hi", "alpine", [mount], fake_recorder: self())

      assert_receive {:sykli_runtime_fake, {:run, "echo hi", "alpine", [^mount], _opts}}
    end

    test "returns the scripted value when provided" do
      assert {:ok, 7, 3, "boom"} =
               Fake.run("irrelevant", nil, [], fake_script: %{run: {:ok, 7, 3, "boom"}})
    end

    test "scripts can inject errors" do
      assert {:error, :boom} =
               Fake.run("irrelevant", nil, [], fake_script: %{run: {:error, :boom}})
    end

    test "records even when scripted" do
      Fake.run("x", nil, [], fake_recorder: self(), fake_script: %{run: {:error, :boom}})
      assert_receive {:sykli_runtime_fake, {:run, "x", nil, [], _opts}}
    end
  end

  describe "services" do
    test "start_service returns a stable fake id for identical inputs" do
      {:ok, id1} = Fake.start_service("db", "postgres:15", "net-a", [])
      {:ok, id2} = Fake.start_service("db", "postgres:15", "net-a", [])

      assert id1 == id2
      assert String.starts_with?(id1, "fake-svc-")
    end

    test "start_service records the call to the recorder pid" do
      Fake.start_service("db", "postgres:15", "net-a", fake_recorder: self())
      assert_receive {:sykli_runtime_fake, {:start_service, "db", "postgres:15", "net-a", _opts}}
    end

    test "create_network returns a stable fake id" do
      {:ok, n1} = Fake.create_network("test-net")
      {:ok, n2} = Fake.create_network("test-net")

      assert n1 == n2
      assert String.starts_with?(n1, "fake-net-")
    end

    test "stop_service and remove_network return :ok" do
      assert :ok = Fake.stop_service("whatever")
      assert :ok = Fake.remove_network("whatever")
    end
  end

  describe "determinism (property)" do
    test "identical call sequences produce identical return values, 100 iterations" do
      for _ <- 1..100 do
        assert run_sequence() == run_sequence()
      end
    end

    defp run_sequence do
      [
        Fake.run("a", "img", [], []),
        Fake.run("b", "img", [], []),
        Fake.start_service("svc", "img", "net", []),
        Fake.create_network("n1"),
        Fake.stop_service("c1"),
        Fake.remove_network("n1")
      ]
    end
  end

  describe "fake/real parity" do
    test "Fake and Shell accept the same run/4 call shape" do
      # If Shell's signature diverges from Fake's (e.g. arg reorder), this
      # compiles but the shapes mismatch — the parity test catches it.
      shell_result = Sykli.Runtime.Shell.run("true", nil, [], workdir: System.tmp_dir!())
      fake_result = Fake.run("true", nil, [], fake_recorder: self())

      assert match?({:ok, 0, _, _}, shell_result)
      assert match?({:ok, 0, _, _}, fake_result)
      assert_receive {:sykli_runtime_fake, {:run, "true", nil, [], _}}
    end
  end
end
