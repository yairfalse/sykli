defmodule Sykli.Runtime.BehaviourTest do
  @moduledoc """
  Regression guard on the Sykli.Runtime.Behaviour contract.

  This test pins:
  - which modules declare `@behaviour Sykli.Runtime.Behaviour`
  - which callbacks are required
  - which callbacks are optional

  If you change the behaviour signature, update this test deliberately.
  Silent drift is the failure mode this guards against.
  """

  use ExUnit.Case, async: true

  @runtime_dir Path.expand("../../../lib/sykli/runtime", __DIR__)
  @implementations @runtime_dir
                   |> Path.join("*.ex")
                   |> Path.wildcard()
                   |> Enum.reject(&(Path.basename(&1) in ["behaviour.ex", "resolver.ex"]))
                   |> Enum.map(fn path ->
                     path
                     |> Path.basename(".ex")
                     |> Macro.camelize()
                     |> then(&Module.concat([Sykli, Runtime, &1]))
                   end)

  describe "behaviour declarations" do
    for impl <- @implementations do
      @impl_mod impl
      test "#{inspect(impl)} declares @behaviour Sykli.Runtime.Behaviour" do
        behaviours =
          @impl_mod.module_info(:attributes)
          |> Keyword.get_values(:behaviour)
          |> List.flatten()

        assert Sykli.Runtime.Behaviour in behaviours
      end
    end
  end

  describe "required callbacks" do
    test "name/0, available?/0, run/4 are required" do
      all = Sykli.Runtime.Behaviour.behaviour_info(:callbacks)
      optional = Sykli.Runtime.Behaviour.behaviour_info(:optional_callbacks)
      required = all -- optional

      assert {:name, 0} in required
      assert {:available?, 0} in required
      assert {:run, 4} in required
    end
  end

  describe "optional callbacks" do
    test "service and network callbacks are optional" do
      optional = Sykli.Runtime.Behaviour.behaviour_info(:optional_callbacks)

      assert {:start_service, 4} in optional
      assert {:stop_service, 1} in optional
      assert {:create_network, 1} in optional
      assert {:remove_network, 1} in optional
    end
  end
end
