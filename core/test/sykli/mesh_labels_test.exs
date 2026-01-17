defmodule Sykli.MeshLabelsTest do
  use ExUnit.Case, async: true

  alias Sykli.Mesh
  alias Sykli.NodeProfile

  describe "local_capabilities/0 integration" do
    test "includes labels from NodeProfile" do
      caps = Mesh.local_capabilities()

      assert Map.has_key?(caps, :labels)
      assert is_list(caps.labels)
    end

    test "labels include OS and arch" do
      caps = Mesh.local_capabilities()

      # Should have auto-detected labels
      assert Enum.any?(caps.labels, &(&1 in ["darwin", "linux", "windows"]))
      assert Enum.any?(caps.labels, &(&1 in ["arm64", "amd64", "x86_64"]))
    end

    test "capabilities include cpus and memory" do
      caps = Mesh.local_capabilities()

      assert is_integer(caps.cpus)
      assert caps.cpus > 0
      assert is_integer(caps.memory_mb)
      assert caps.memory_mb > 0
    end
  end

  describe "local_capabilities/0 with SYKLI_LABELS" do
    setup do
      original = System.get_env("SYKLI_LABELS")

      on_exit(fn ->
        if original,
          do: System.put_env("SYKLI_LABELS", original),
          else: System.delete_env("SYKLI_LABELS")
      end)

      :ok
    end

    test "includes user-defined labels" do
      System.put_env("SYKLI_LABELS", "docker,gpu,team:ml")

      caps = Mesh.local_capabilities()

      assert "docker" in caps.labels
      assert "gpu" in caps.labels
      assert "team:ml" in caps.labels
    end
  end

  describe "node_info/1 integration" do
    test "local node info includes labels" do
      info = Mesh.node_info(:local)

      assert Map.has_key?(info.capabilities, :labels)
      assert is_list(info.capabilities.labels)
    end
  end
end
