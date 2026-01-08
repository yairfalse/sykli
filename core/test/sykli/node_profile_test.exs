defmodule Sykli.NodeProfileTest do
  use ExUnit.Case, async: true

  alias Sykli.NodeProfile

  describe "labels/0" do
    test "includes os label" do
      labels = NodeProfile.labels()

      # Should have exactly one of these
      assert "darwin" in labels or "linux" in labels or "windows" in labels
    end

    test "includes arch label" do
      labels = NodeProfile.labels()

      # Should have exactly one of these
      assert "arm64" in labels or "amd64" in labels or "x86_64" in labels
    end

    test "returns strings, not atoms" do
      labels = NodeProfile.labels()

      Enum.each(labels, fn label ->
        assert is_binary(label), "Expected string, got: #{inspect(label)}"
      end)
    end
  end

  describe "user_labels/0 with SYKLI_LABELS" do
    setup do
      # Clean up env before each test
      original = System.get_env("SYKLI_LABELS")
      on_exit(fn ->
        if original, do: System.put_env("SYKLI_LABELS", original), else: System.delete_env("SYKLI_LABELS")
      end)
      :ok
    end

    test "reads labels from SYKLI_LABELS env" do
      System.put_env("SYKLI_LABELS", "docker,gpu")

      labels = NodeProfile.user_labels()

      assert "docker" in labels
      assert "gpu" in labels
    end

    test "returns empty list when SYKLI_LABELS not set" do
      System.delete_env("SYKLI_LABELS")

      assert NodeProfile.user_labels() == []
    end

    test "handles empty SYKLI_LABELS" do
      System.put_env("SYKLI_LABELS", "")

      assert NodeProfile.user_labels() == []
    end

    test "strips whitespace from labels" do
      System.put_env("SYKLI_LABELS", " docker , gpu , builder ")

      labels = NodeProfile.user_labels()

      assert "docker" in labels
      assert "gpu" in labels
      assert "builder" in labels
      # No whitespace
      refute " docker" in labels
      refute "docker " in labels
    end

    test "supports namespaced labels" do
      System.put_env("SYKLI_LABELS", "team:ml,region:us-east,env:prod")

      labels = NodeProfile.user_labels()

      assert "team:ml" in labels
      assert "region:us-east" in labels
      assert "env:prod" in labels
    end

    test "ignores empty segments" do
      System.put_env("SYKLI_LABELS", "docker,,gpu,")

      labels = NodeProfile.user_labels()

      assert labels == ["docker", "gpu"]
    end
  end

  describe "labels/0 combines base and user labels" do
    setup do
      original = System.get_env("SYKLI_LABELS")
      on_exit(fn ->
        if original, do: System.put_env("SYKLI_LABELS", original), else: System.delete_env("SYKLI_LABELS")
      end)
      :ok
    end

    test "includes both base and user labels" do
      System.put_env("SYKLI_LABELS", "docker,gpu")

      labels = NodeProfile.labels()

      # Base labels (auto-detected)
      assert "darwin" in labels or "linux" in labels
      assert "arm64" in labels or "amd64" in labels or "x86_64" in labels

      # User labels
      assert "docker" in labels
      assert "gpu" in labels
    end
  end

  describe "capabilities/0" do
    test "returns map with labels" do
      caps = NodeProfile.capabilities()

      assert is_map(caps)
      assert is_list(caps.labels)
    end

    test "includes cpus" do
      caps = NodeProfile.capabilities()

      assert is_integer(caps.cpus)
      assert caps.cpus > 0
    end

    test "includes memory_mb" do
      caps = NodeProfile.capabilities()

      assert is_integer(caps.memory_mb)
      assert caps.memory_mb > 0
    end
  end

  describe "has_label?/1" do
    setup do
      original = System.get_env("SYKLI_LABELS")
      System.put_env("SYKLI_LABELS", "docker,gpu")
      on_exit(fn ->
        if original, do: System.put_env("SYKLI_LABELS", original), else: System.delete_env("SYKLI_LABELS")
      end)
      :ok
    end

    test "returns true for present label" do
      assert NodeProfile.has_label?("docker")
    end

    test "returns false for missing label" do
      refute NodeProfile.has_label?("kubernetes")
    end

    test "works with base labels" do
      # At least one of these should be true
      assert NodeProfile.has_label?("darwin") or
             NodeProfile.has_label?("linux") or
             NodeProfile.has_label?("windows")
    end
  end
end
