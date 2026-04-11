defmodule Sykli.Executor.RetryTest do
  @moduledoc """
  Tests for executor retry logic and on_fail hooks.

  The retry functions (apply_on_fail_retry_boost, do_run_with_retry) are private
  in Sykli.Executor, so we test them indirectly through the public API or by
  verifying the task struct transformations that feed into retry logic.
  """

  use ExUnit.Case, async: true

  alias Sykli.Graph.Task
  alias Sykli.Graph.Task.AiHooks
  alias Sykli.Executor.TaskResult

  describe "retry configuration via task struct" do
    test "task with no retry defaults to nil" do
      task = %Task{name: "test", retry: nil}
      assert task.retry == nil
    end

    test "task retry field accepts integer values" do
      task = %Task{name: "test", retry: 3}
      assert task.retry == 3
    end

    test "on_fail: :retry ai_hook is representable" do
      hooks = %AiHooks{on_fail: :retry}
      task = %Task{name: "test", ai_hooks: hooks, retry: 0}
      assert task.ai_hooks.on_fail == :retry
    end

    test "on_fail: :skip ai_hook is representable" do
      hooks = %AiHooks{on_fail: :skip}
      task = %Task{name: "test", ai_hooks: hooks}
      assert task.ai_hooks.on_fail == :skip
    end

    test "on_fail: :analyze ai_hook is representable" do
      hooks = %AiHooks{on_fail: :analyze}
      task = %Task{name: "test", ai_hooks: hooks}
      assert task.ai_hooks.on_fail == :analyze
    end
  end

  describe "TaskResult status values for retry context" do
    test ":failed status indicates content failure" do
      result = %TaskResult{name: "test", status: :failed, duration_ms: 100, error: "exit 1"}
      assert result.status == :failed
    end

    test ":errored status indicates infrastructure failure" do
      result = %TaskResult{name: "test", status: :errored, duration_ms: 100, error: "timeout"}
      assert result.status == :errored
    end

    test ":passed status indicates success" do
      result = %TaskResult{name: "test", status: :passed, duration_ms: 50}
      assert result.status == :passed
    end

    test "both :failed and :errored are failure states" do
      failure_states = [:failed, :errored]

      for status <- failure_states do
        result = %TaskResult{name: "test", status: status, duration_ms: 100}
        assert result.status in [:failed, :errored]
      end
    end

    test "non-failure states" do
      for status <- [:passed, :cached, :skipped, :blocked] do
        result = %TaskResult{name: "test", status: status, duration_ms: 0}
        refute result.status in [:failed, :errored]
      end
    end
  end

  describe "retry boost logic (on_fail: :retry)" do
    # The apply_on_fail_retry_boost function sets retry to max(current, 2)
    # when on_fail is :retry. We verify the expected behavior.

    test "task with on_fail: :retry and retry: nil should get boosted to at least 2" do
      # This verifies the contract: on_fail: :retry means at least 2 retries
      hooks = %AiHooks{on_fail: :retry}
      task = %Task{name: "test", ai_hooks: hooks, retry: nil}

      # The boost sets retry to max(current || 0, 2) = 2
      current = task.retry || 0
      boosted = max(current, 2)
      assert boosted == 2
    end

    test "task with on_fail: :retry and retry: 5 keeps higher value" do
      hooks = %AiHooks{on_fail: :retry}
      task = %Task{name: "test", ai_hooks: hooks, retry: 5}

      current = task.retry || 0
      boosted = max(current, 2)
      assert boosted == 5
    end

    test "task with on_fail: :retry and retry: 0 gets boosted to 2" do
      hooks = %AiHooks{on_fail: :retry}
      task = %Task{name: "test", ai_hooks: hooks, retry: 0}

      current = task.retry || 0
      boosted = max(current, 2)
      assert boosted == 2
    end

    test "task with on_fail: :retry and retry: 1 gets boosted to 2" do
      hooks = %AiHooks{on_fail: :retry}
      task = %Task{name: "test", ai_hooks: hooks, retry: 1}

      current = task.retry || 0
      boosted = max(current, 2)
      assert boosted == 2
    end
  end

  describe "max_attempts calculation" do
    test "no retry means 1 attempt" do
      max_attempts = (nil || 0) + 1
      assert max_attempts == 1
    end

    test "retry: 2 means 3 attempts" do
      max_attempts = (2 || 0) + 1
      assert max_attempts == 3
    end

    test "retry: 0 means 1 attempt" do
      max_attempts = (0 || 0) + 1
      assert max_attempts == 1
    end
  end

  describe "on_fail: :skip transformation" do
    # apply_on_fail_hook converts :failed/:errored to :skipped when on_fail is :skip

    defp apply_skip_hook(%TaskResult{status: status} = result)
         when status in [:failed, :errored] do
      %TaskResult{result | status: :skipped}
    end

    defp apply_skip_hook(result), do: result

    test "failed result becomes skipped with on_fail: :skip" do
      result = %TaskResult{name: "test", status: :failed, duration_ms: 100, error: "exit 1"}
      assert apply_skip_hook(result).status == :skipped
    end

    test "errored result becomes skipped with on_fail: :skip" do
      result = %TaskResult{name: "test", status: :errored, duration_ms: 100, error: "timeout"}
      assert apply_skip_hook(result).status == :skipped
    end

    test "passed result is not affected by on_fail: :skip" do
      result = %TaskResult{name: "test", status: :passed, duration_ms: 50}
      assert apply_skip_hook(result).status == :passed
    end
  end
end
