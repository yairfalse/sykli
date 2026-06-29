defmodule Sykli.Cache.TieredRepositoryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Sykli.Cache.TieredRepository

  @failure_threshold 5
  @default_test_cooldown_ms 1_000

  setup do
    old_cooldown = Application.get_env(:sykli, :s3_circuit_cooldown_ms)

    Application.put_env(:sykli, :s3_circuit_cooldown_ms, @default_test_cooldown_ms)
    TieredRepository.ensure_circuit_table()
    TieredRepository.__reset_circuit__()

    on_exit(fn ->
      restore_cooldown(old_cooldown)
      TieredRepository.ensure_circuit_table()
      TieredRepository.__reset_circuit__()
    end)

    :ok
  end

  describe "S3 circuit breaker" do
    test "initial state is closed with zero failures" do
      assert TieredRepository.__circuit_closed?()
      assert %{failures: 0, open_until: 0} = TieredRepository.__circuit_state__()
    end

    test "opens after exactly the failure threshold" do
      for _ <- 1..(@failure_threshold - 1) do
        TieredRepository.__record_failure__()
      end

      assert %{failures: 4, open_until: 0} = TieredRepository.__circuit_state__()
      assert TieredRepository.__circuit_closed?()

      log =
        capture_log(fn ->
          TieredRepository.__record_failure__()
        end)

      state = TieredRepository.__circuit_state__()
      assert state.failures == @failure_threshold
      assert state.open_until > now_ms()
      refute TieredRepository.__circuit_closed?()

      assert log =~
               "[TieredCache] S3 circuit breaker OPEN after 5 consecutive failures " <>
                 "(cooldown: #{@default_test_cooldown_ms}ms)"
    end

    test "success resets the consecutive failure count and closes the breaker" do
      open_circuit()
      refute TieredRepository.__circuit_closed?()

      log =
        capture_log(fn ->
          TieredRepository.__record_success__()
        end)

      assert %{failures: 0, open_until: 0} = TieredRepository.__circuit_state__()
      assert TieredRepository.__circuit_closed?()
      assert log =~ "[TieredCache] S3 circuit breaker closed (recovered)"
    end

    test "after cooldown elapses the breaker allows a half-open probe" do
      Application.put_env(:sykli, :s3_circuit_cooldown_ms, 5)

      open_circuit()
      refute TieredRepository.__circuit_closed?()

      Process.sleep(10)
      assert TieredRepository.__circuit_closed?()

      Application.put_env(:sykli, :s3_circuit_cooldown_ms, @default_test_cooldown_ms)
      TieredRepository.__record_failure__()

      state = TieredRepository.__circuit_state__()
      assert state.failures == @failure_threshold + 1
      assert state.open_until > now_ms()
      refute TieredRepository.__circuit_closed?()
    end

    test "concurrent failures are counted atomically without lost increments" do
      failures = 50

      {results, log} =
        capture_result_and_log(fn ->
          1..failures
          |> Task.async_stream(
            fn _ ->
              TieredRepository.__record_failure__()
            end,
            max_concurrency: failures,
            timeout: 5_000
          )
          |> Enum.to_list()
        end)

      assert Enum.all?(results, &match?({:ok, _}, &1))

      state = TieredRepository.__circuit_state__()
      assert state.failures == failures
      assert state.open_until > now_ms()
      refute TieredRepository.__circuit_closed?()

      assert Regex.scan(~r/S3 circuit breaker OPEN after/, log) |> length() == 1
    end
  end

  defp open_circuit do
    capture_log(fn ->
      for _ <- 1..@failure_threshold do
        TieredRepository.__record_failure__()
      end
    end)
  end

  defp capture_result_and_log(fun) do
    ref = make_ref()
    test_pid = self()

    log =
      capture_log(fn ->
        result = fun.()
        send(test_pid, {ref, result})
      end)

    receive do
      {^ref, result} -> {result, log}
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp restore_cooldown(nil), do: Application.delete_env(:sykli, :s3_circuit_cooldown_ms)

  defp restore_cooldown(value),
    do: Application.put_env(:sykli, :s3_circuit_cooldown_ms, value)
end
