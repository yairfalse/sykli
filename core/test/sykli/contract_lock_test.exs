defmodule Sykli.ContractLockTest do
  use ExUnit.Case, async: false

  alias Sykli.ContractLock

  @contract %{
    "version" => "4",
    "tasks" => [
      %{
        "name" => "test",
        "command" => "mix test",
        "success_criteria" => [%{"type" => "exit_code", "value" => 0}]
      }
    ]
  }

  @changed_contract put_in(@contract, ["tasks", Access.at(0), "name"], "test-2")

  test "build encode decode verify round-trips" do
    lock = ContractLock.build(@contract, "/tmp/project/sykli.exs")

    assert {:ok, bytes} = ContractLock.encode(lock)
    assert {:ok, decoded} = ContractLock.decode(bytes)
    assert :ok = ContractLock.verify_contract(@contract, decoded)
    assert decoded["sdk_file"] == "sykli.exs"
    assert decoded["schema_version"] == "4"
  end

  test "lock encoding is deterministic" do
    lock = ContractLock.build(@contract, "sykli.exs")

    assert ContractLock.encode(lock) == ContractLock.encode(lock)
  end

  test "decode rejects bad json, missing keys, and wrong internal hash" do
    assert {:error, %{code: "contract.lock_corrupt"}} = ContractLock.decode("{")

    assert {:error, %{code: "contract.lock_corrupt"}} =
             ContractLock.decode(~s({"version":"1"}))

    lock = ContractLock.build(@contract, "sykli.exs") |> Map.put("contract_hash", "sha256:bad")

    assert {:error, %{code: "contract.lock_corrupt"}} =
             lock |> Jason.encode!() |> ContractLock.decode()
  end

  test "verify_contract detects mismatch" do
    lock = ContractLock.build(@contract, "sykli.exs")
    changed = put_in(@contract, ["tasks", Access.at(0), "command"], "mix test --failed")

    assert {:error, error} = ContractLock.verify_contract(changed, lock)
    assert error.code == "contract.lock_mismatch"
    assert Enum.any?(error.hints, &String.contains?(&1, "sykli lock"))
  end

  test "double_emit rejects nondeterministic contracts" do
    {:ok, agent} =
      Agent.start_link(fn -> [Jason.encode!(@contract), Jason.encode!(@changed_contract)] end)

    {:error, error} =
      ContractLock.double_emit(fn ->
        {:ok, Agent.get_and_update(agent, fn [head | tail] -> {head, tail} end)}
      end)

    assert error.code == "contract.nondeterministic"
  end

  test "verify_project uses injected detector and emit source" do
    tmp = Path.join(System.tmp_dir!(), "sykli-lock-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    sdk = Path.join(tmp, "sykli.exs")
    File.write!(sdk, "")

    lock = ContractLock.build(@contract, sdk)
    assert {:ok, _} = ContractLock.write(lock, Path.join(tmp, "sykli.lock"))

    emit_fun = fn {^sdk, _runner} -> {:ok, Jason.encode!(@contract)} end

    assert {:ok, %{hash: hash}} =
             ContractLock.verify_project(tmp,
               detector: __MODULE__.FakeDetector,
               emit_fun: emit_fun
             )

    assert hash == lock["contract_hash"]
  end

  defmodule FakeDetector do
    def find(path), do: {:ok, {Path.join(path, "sykli.exs"), fn _ -> :unused end}}
  end
end
