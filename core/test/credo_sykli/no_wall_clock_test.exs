defmodule CredoSykli.NoWallClockTest do
  use Credo.Test.Case, async: true

  alias CredoSykli.Check.NoWallClock

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  test "System.monotonic_time in lib/sykli/foo.ex produces one issue" do
    fixture("bad_system_monotonic_time.ex", "lib/sykli/foo.ex")
    |> run_check(NoWallClock, severity: :error)
    |> assert_issue(fn issue ->
      assert issue.trigger == "System.monotonic_time"
      assert issue.line_no == 2
      assert issue.severity == :error
    end)
  end

  test "System.monotonic_time in lib/sykli/mesh/transport/erlang.ex produces zero issues" do
    fixture("excluded_erlang_transport.ex", "lib/sykli/mesh/transport/erlang.ex")
    |> run_check(NoWallClock, severity: :error)
    |> refute_issues()
  end

  test "clean fixture produces zero issues" do
    fixture("clean.ex", "lib/sykli/clean.ex")
    |> run_check(NoWallClock, severity: :error)
    |> refute_issues()
  end

  test "detects System.os_time" do
    fixture("bad_system_os_time.ex", "lib/sykli/foo.ex")
    |> run_check(NoWallClock, severity: :error)
    |> assert_issue(%{trigger: "System.os_time"})
  end

  test "detects :os.system_time" do
    fixture("bad_os_system_time.ex", "lib/sykli/foo.ex")
    |> run_check(NoWallClock, severity: :error)
    |> assert_issue(%{trigger: ":os.system_time"})
  end

  test "detects :erlang.now" do
    fixture("bad_erlang_now.ex", "lib/sykli/foo.ex")
    |> run_check(NoWallClock, severity: :error)
    |> assert_issue(%{trigger: ":erlang.now"})
  end

  test "detects DateTime.utc_now" do
    fixture("bad_datetime_utc_now.ex", "lib/sykli/foo.ex")
    |> run_check(NoWallClock, severity: :error)
    |> assert_issue(%{trigger: "DateTime.utc_now"})
  end

  test "detects NaiveDateTime.utc_now" do
    fixture("bad_naive_datetime_utc_now.ex", "lib/sykli/foo.ex")
    |> run_check(NoWallClock, severity: :error)
    |> assert_issue(%{trigger: "NaiveDateTime.utc_now"})
  end

  test "detects unary :rand.uniform" do
    fixture("bad_rand_uniform.ex", "lib/sykli/foo.ex")
    |> run_check(NoWallClock, severity: :error)
    |> assert_issue(%{trigger: ":rand.uniform"})
  end

  defp fixture(name, target_filename) do
    path = Path.expand("../fixtures/credo_sykli/#{name}", __DIR__)
    path |> File.read!() |> to_source_file(target_filename)
  end
end
