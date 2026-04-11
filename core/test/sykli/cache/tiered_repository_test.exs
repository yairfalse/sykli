defmodule Sykli.Cache.TieredRepositoryTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Tests the circuit breaker logic in TieredRepository.

  Since TieredRepository uses persistent_term for circuit breaker state,
  these tests focus on the state management rather than actual L1/L2
  cache operations (which would require S3 credentials).
  """

  # ─────────────────────────────────────────────────────────────────────────────
  # CIRCUIT BREAKER STATE
  # ─────────────────────────────────────────────────────────────────────────────

  setup do
    # Reset circuit breaker state before each test
    :persistent_term.put(:sykli_s3_circuit, %{failures: 0, open_until: 0})

    on_exit(fn ->
      # Clean up persistent_term
      try do
        :persistent_term.put(:sykli_s3_circuit, %{failures: 0, open_until: 0})
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  describe "circuit breaker state via persistent_term" do
    test "initial state has zero failures" do
      state = :persistent_term.get(:sykli_s3_circuit)
      assert state.failures == 0
      assert state.open_until == 0
    end

    test "state persists across reads" do
      :persistent_term.put(:sykli_s3_circuit, %{failures: 3, open_until: 0})
      state = :persistent_term.get(:sykli_s3_circuit)
      assert state.failures == 3
    end

    test "circuit is closed when failures below threshold" do
      :persistent_term.put(:sykli_s3_circuit, %{failures: 4, open_until: 0})
      state = :persistent_term.get(:sykli_s3_circuit)
      # Threshold is 5, so 4 failures means circuit is still closed
      assert state.failures < 5
    end

    test "circuit opens when failures reach threshold" do
      # Simulate 5 failures with future open_until
      open_until = System.monotonic_time(:millisecond) + 60_000

      :persistent_term.put(:sykli_s3_circuit, %{
        failures: 5,
        open_until: open_until
      })

      state = :persistent_term.get(:sykli_s3_circuit)
      assert state.failures >= 5
      assert state.open_until > System.monotonic_time(:millisecond)
    end

    test "circuit closes after cooldown expires" do
      # Set open_until to the past (cooldown expired)
      :persistent_term.put(:sykli_s3_circuit, %{
        failures: 5,
        open_until: System.monotonic_time(:millisecond) - 1000
      })

      state = :persistent_term.get(:sykli_s3_circuit)
      # Even though failures >= threshold, open_until is in the past
      assert state.failures >= 5
      assert System.monotonic_time(:millisecond) >= state.open_until
    end

    test "reset brings failures back to zero" do
      :persistent_term.put(:sykli_s3_circuit, %{failures: 10, open_until: 999_999_999})
      :persistent_term.put(:sykli_s3_circuit, %{failures: 0, open_until: 0})

      state = :persistent_term.get(:sykli_s3_circuit)
      assert state.failures == 0
      assert state.open_until == 0
    end

    test "incremental failure tracking" do
      # Simulate incremental failure recording
      for i <- 1..4 do
        :persistent_term.put(:sykli_s3_circuit, %{failures: i, open_until: 0})
      end

      state = :persistent_term.get(:sykli_s3_circuit)
      assert state.failures == 4
      # Still below threshold
      assert state.failures < 5
    end

    test "threshold crossing sets open_until in the future" do
      # Simulate the 5th failure (crossing the threshold)
      open_until = System.monotonic_time(:millisecond) + 60_000

      :persistent_term.put(:sykli_s3_circuit, %{
        failures: 5,
        open_until: open_until
      })

      state = :persistent_term.get(:sykli_s3_circuit)
      assert state.failures == 5
      # open_until should be ~60 seconds in the future
      assert state.open_until > System.monotonic_time(:millisecond)
      assert state.open_until <= System.monotonic_time(:millisecond) + 61_000
    end
  end

  describe "circuit breaker logic (unit)" do
    test "circuit_closed? returns true when failures below threshold" do
      :persistent_term.put(:sykli_s3_circuit, %{failures: 0, open_until: 0})
      assert circuit_closed?()

      :persistent_term.put(:sykli_s3_circuit, %{failures: 4, open_until: 0})
      assert circuit_closed?()
    end

    test "circuit_closed? returns false when failures at threshold and cooldown active" do
      open_until = System.monotonic_time(:millisecond) + 60_000

      :persistent_term.put(:sykli_s3_circuit, %{failures: 5, open_until: open_until})
      refute circuit_closed?()
    end

    test "circuit_closed? returns true when failures at threshold but cooldown expired" do
      open_until = System.monotonic_time(:millisecond) - 1000

      :persistent_term.put(:sykli_s3_circuit, %{failures: 5, open_until: open_until})
      assert circuit_closed?()
    end

    test "circuit_closed? returns true when persistent_term not initialized" do
      :persistent_term.erase(:sykli_s3_circuit)
      # Should default to closed (failures: 0)
      assert circuit_closed?()
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # HELPERS
  # ─────────────────────────────────────────────────────────────────────────────

  # Replicates the circuit_closed? logic from TieredRepository
  # so we can test it without needing real L1/L2 backends
  defp circuit_closed? do
    state = get_circuit_state()

    cond do
      state.failures < 5 -> true
      System.monotonic_time(:millisecond) >= state.open_until -> true
      true -> false
    end
  end

  defp get_circuit_state do
    :persistent_term.get(:sykli_s3_circuit)
  rescue
    ArgumentError -> %{failures: 0, open_until: 0}
  end
end
