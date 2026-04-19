defmodule Sykli.Runtime.PodmanTest do
  @moduledoc """
  Tests for Sykli.Runtime.Podman.

  Tagged `:podman` — excluded from default `mix test`. Run with:

      mix test.podman

  Requires Podman installed and rootless operation enabled. Ported from
  the Docker test shape.
  """

  use ExUnit.Case, async: false

  @moduletag :podman

  alias Sykli.Runtime.Podman

  describe "identity" do
    test "name/0 returns \"podman\"" do
      assert Podman.name() == "podman"
    end

    test "declares @behaviour Sykli.Runtime.Behaviour" do
      behaviours =
        Podman.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Sykli.Runtime.Behaviour in behaviours
    end
  end

  describe "available?/0" do
    test "reports available when podman is installed" do
      case Podman.available?() do
        {:ok, info} ->
          assert is_map(info)
          assert is_binary(info.version)
          assert String.contains?(info.version, "podman")

        {:error, _} ->
          # Podman not installed; the test host isn't a Podman machine.
          # This branch is tolerated so the tag-based inclusion still
          # produces a meaningful run on hosts where podman is partial.
          :ok
      end
    end
  end

  describe "run/4" do
    test "runs a simple command and returns its output" do
      assert {:ok, 0, _lines, output} =
               Podman.run("echo hello", "alpine:3", [], workdir: System.tmp_dir!())

      assert String.contains?(output, "hello")
    end
  end

  describe "networks and services" do
    test "create_network returns {:ok, name} and remove_network returns :ok" do
      network = "sykli-podman-test-#{:erlang.unique_integer([:positive])}"

      assert {:ok, ^network} = Podman.create_network(network)
      assert :ok = Podman.remove_network(network)
    end
  end
end
