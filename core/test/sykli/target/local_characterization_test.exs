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

  defmodule UnavailableRuntime do
    @behaviour Sykli.Runtime.Behaviour

    @impl true
    def name, do: "unavailable"

    @impl true
    def available?, do: {:error, :unavailable}

    @impl true
    def run(_command, _image, _mounts, _opts), do: {:ok, 0, 0, ""}
  end

  describe "setup/1 — runtime selection (characterization)" do
    test "with no opts, under :test config, resolves to Sykli.Runtime.Fake" do
      {:ok, state} = Local.setup(workdir: System.tmp_dir!())

      assert state.runtime == Sykli.Runtime.Fake

      Local.teardown(state)
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

  describe "containerless composition (RC.4c)" do
    test "by default, containerless_runtime is Sykli.Runtime.Shell" do
      {:ok, state} = Local.setup(workdir: System.tmp_dir!())

      assert state.containerless_runtime == Sykli.Runtime.Shell

      Local.teardown(state)
    end

    test "containerless_runtime opt overrides the default" do
      {:ok, state} =
        Local.setup(
          workdir: System.tmp_dir!(),
          containerless_runtime: Sykli.Runtime.Fake
        )

      assert state.containerless_runtime == Sykli.Runtime.Fake

      Local.teardown(state)
    end

    test "setup fails early when the containerless runtime is unavailable" do
      assert {:error, :unavailable} =
               Local.setup(
                 workdir: System.tmp_dir!(),
                 runtime: Sykli.Runtime.Fake,
                 containerless_runtime: UnavailableRuntime
               )
    end

    test "a task with container: nil dispatches to the containerless runtime" do
      # Uses Fake as containerless. Fake.run/4 returns {:ok, 0, 0, ""} for any
      # input; if the dispatch were still going through Shell (pre-RC.4c
      # behaviour), this nonsense command would fail with exit code /= 0 and
      # run_task would return {:error, _}. Success therefore proves the
      # containerless_runtime field is what's being dispatched to.
      {:ok, state} =
        Local.setup(
          workdir: System.tmp_dir!(),
          runtime: Sykli.Runtime.Fake,
          containerless_runtime: Sykli.Runtime.Fake
        )

      task = %Sykli.Graph.Task{
        name: "containerless-fake",
        command: "/nonexistent/binary --proves-fake-was-hit",
        container: nil,
        mounts: [],
        env: %{}
      }

      assert {:ok, _} = Local.run_task(task, state, [])

      Local.teardown(state)
    end
  end
end
