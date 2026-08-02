defmodule Sykli.CLI.ContractTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  alias Sykli.CLI.Contract
  alias Sykli.ContractLock

  defmodule FakeDetector do
    def find(path), do: {:ok, {Path.join(path, "sykli.exs"), :fake}}
  end

  @locked %{
    "version" => "5",
    "tasks" => [
      %{
        "name" => "test",
        "command" => "mix test",
        "success_criteria" => [%{"type" => "exit_code", "equals" => 0}]
      }
    ]
  }

  test "diff exits non-zero when the current contract weakens the lock", %{tmp_dir: tmp_dir} do
    current = put_in(@locked, ["tasks", Access.at(0), "success_criteria"], [])
    lock_path = write_lock!(tmp_dir, @locked)

    output =
      capture_io(fn ->
        assert Contract.run(["--diff", tmp_dir, lock_path], opts(current)) == 1
      end)

    assert output =~ "Verdict: weakening present"
  end

  defp write_lock!(tmp_dir, contract) do
    lock_path = Path.join(tmp_dir, "sykli.lock")
    lock = ContractLock.build(contract, Path.join(tmp_dir, "sykli.exs"))
    assert {:ok, _bytes} = ContractLock.write(lock, lock_path)
    lock_path
  end

  defp opts(contract) do
    [
      detector: FakeDetector,
      emit_fun: fn _sdk -> {:ok, Jason.encode!(contract)} end
    ]
  end
end
