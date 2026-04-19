defmodule Sykli.Target.LocalCharacterizationTest do
  @moduledoc """
  Pins the current runtime-selection behavior of Sykli.Target.Local.

  These tests exist to guard against unintended behavior change during the
  runtime-decoupling refactor (RC.1–RC.7). They pass before AND after the
  refactor; new assertions are added as steps complete that introduce new
  behavior — RC.4b adds a Fake-default case, RC.4c adds containerless
  composition.

  The `setup/1` default-runtime test tolerates both outcomes (Docker present
  vs. absent) because the pre-refactor default is `Sykli.Runtime.Docker` and
  the project does not yet exclude `:docker` by default. RC.4b tightens the
  default-runtime assertion once the Resolver is wired in.
  """

  use ExUnit.Case, async: false

  alias Sykli.Target.Local

  describe "setup/1 — runtime selection (characterization)" do
    test "with no opts, either resolves a Runtime.Behaviour impl or fails consistently" do
      case Local.setup(workdir: System.tmp_dir!()) do
        {:ok, state} ->
          assert is_atom(state.runtime)
          assert function_exported?(state.runtime, :name, 0)
          assert function_exported?(state.runtime, :available?, 0)
          assert function_exported?(state.runtime, :run, 4)
          Local.teardown(state)

        {:error, _reason} ->
          # Pre-refactor: setup fails when the hardcoded Docker default is
          # unavailable. This branch disappears in RC.4b when the Resolver
          # picks the Fake runtime under test config.
          :ok
      end
    end

    test "explicit runtime: Sykli.Runtime.Shell is honored" do
      {:ok, state} = Local.setup(workdir: System.tmp_dir!(), runtime: Sykli.Runtime.Shell)

      assert state.runtime == Sykli.Runtime.Shell

      Local.teardown(state)
    end
  end

  describe "run_task/3 — containerless fallback (characterization)" do
    test "a task with container: nil runs via shell when Shell is configured" do
      {:ok, state} = Local.setup(workdir: System.tmp_dir!(), runtime: Sykli.Runtime.Shell)

      task = %Sykli.Graph.Task{
        name: "characterization-true",
        command: "true",
        container: nil,
        mounts: [],
        env: %{}
      }

      assert {:ok, _output} = Local.run_task(task, state, [])

      Local.teardown(state)
    end
  end
end
