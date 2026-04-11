defmodule Sykli.Services.GateServiceTest do
  use ExUnit.Case, async: false

  alias Sykli.Services.GateService
  alias Sykli.Graph.Task.Gate

  @tmp_dir System.tmp_dir!()

  setup do
    on_exit(fn ->
      # Clean up any env vars we set during tests
      System.delete_env("SYKLI_TEST_GATE_APPROVAL")
      System.delete_env("SYKLI_TEST_GATE_EMPTY")
    end)

    :ok
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # ENV STRATEGY
  # ─────────────────────────────────────────────────────────────────────────────

  describe "wait/1 with :env strategy" do
    test "returns approved when env var is 'approved'" do
      System.put_env("SYKLI_TEST_GATE_APPROVAL", "approved")

      gate = %Gate{strategy: :env, env_var: "SYKLI_TEST_GATE_APPROVAL", timeout: 5}
      assert {:approved, "env:SYKLI_TEST_GATE_APPROVAL"} = GateService.wait(gate)
    end

    test "returns approved when env var is '1'" do
      System.put_env("SYKLI_TEST_GATE_APPROVAL", "1")

      gate = %Gate{strategy: :env, env_var: "SYKLI_TEST_GATE_APPROVAL", timeout: 5}
      assert {:approved, "env:SYKLI_TEST_GATE_APPROVAL"} = GateService.wait(gate)
    end

    test "returns approved when env var is 'true'" do
      System.put_env("SYKLI_TEST_GATE_APPROVAL", "true")

      gate = %Gate{strategy: :env, env_var: "SYKLI_TEST_GATE_APPROVAL", timeout: 5}
      assert {:approved, "env:SYKLI_TEST_GATE_APPROVAL"} = GateService.wait(gate)
    end

    test "returns approved when env var is 'yes'" do
      System.put_env("SYKLI_TEST_GATE_APPROVAL", "yes")

      gate = %Gate{strategy: :env, env_var: "SYKLI_TEST_GATE_APPROVAL", timeout: 5}
      assert {:approved, "env:SYKLI_TEST_GATE_APPROVAL"} = GateService.wait(gate)
    end

    test "returns denied when env var is 'denied'" do
      System.put_env("SYKLI_TEST_GATE_APPROVAL", "denied")

      gate = %Gate{strategy: :env, env_var: "SYKLI_TEST_GATE_APPROVAL", timeout: 5}
      assert {:denied, "env:SYKLI_TEST_GATE_APPROVAL"} = GateService.wait(gate)
    end

    test "returns denied when env var has unknown value" do
      System.put_env("SYKLI_TEST_GATE_APPROVAL", "maybe")

      gate = %Gate{strategy: :env, env_var: "SYKLI_TEST_GATE_APPROVAL", timeout: 5}
      assert {:denied, "env:SYKLI_TEST_GATE_APPROVAL"} = GateService.wait(gate)
    end

    test "returns denied when env_var is nil" do
      gate = %Gate{strategy: :env, env_var: nil, timeout: 5}
      assert {:denied, reason} = GateService.wait(gate)
      assert reason =~ "requires env_var"
    end

    test "returns denied when env_var is empty string" do
      gate = %Gate{strategy: :env, env_var: "", timeout: 5}
      assert {:denied, reason} = GateService.wait(gate)
      assert reason =~ "requires env_var"
    end

    test "times out when env var is not set and timeout expires" do
      # Use a very short timeout to avoid slow tests
      # Env var is not set so it will poll until timeout
      System.delete_env("SYKLI_TEST_GATE_EMPTY")

      gate = %Gate{strategy: :env, env_var: "SYKLI_TEST_GATE_EMPTY", timeout: 1}
      # This will take ~1 second due to polling
      assert {:timed_out} = GateService.wait(gate)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # FILE STRATEGY
  # ─────────────────────────────────────────────────────────────────────────────

  describe "wait/1 with :file strategy" do
    test "returns approved when file exists with 'approved' content" do
      path = make_temp_file("approved")

      on_exit(fn -> File.rm(path) end)

      gate = %Gate{strategy: :file, file_path: path, timeout: 5}
      assert {:approved, "file:" <> ^path} = GateService.wait(gate)
    end

    test "returns denied when file contains 'denied'" do
      path = make_temp_file("denied")

      on_exit(fn -> File.rm(path) end)

      gate = %Gate{strategy: :file, file_path: path, timeout: 5}
      assert {:denied, "file:" <> ^path} = GateService.wait(gate)
    end

    test "returns approved when file exists with empty content" do
      path = make_temp_file("")

      on_exit(fn -> File.rm(path) end)

      gate = %Gate{strategy: :file, file_path: path, timeout: 5}
      assert {:approved, "file:" <> ^path} = GateService.wait(gate)
    end

    test "returns approved when file exists with any other content" do
      path = make_temp_file("go ahead")

      on_exit(fn -> File.rm(path) end)

      gate = %Gate{strategy: :file, file_path: path, timeout: 5}
      assert {:approved, "file:" <> ^path} = GateService.wait(gate)
    end

    test "times out when file does not exist" do
      path = Path.join(@tmp_dir, "nonexistent_gate_#{:erlang.unique_integer([:positive])}")

      gate = %Gate{strategy: :file, file_path: path, timeout: 1}
      assert {:timed_out} = GateService.wait(gate)
    end

    test "returns denied when file_path is nil" do
      gate = %Gate{strategy: :file, file_path: nil, timeout: 5}
      assert {:denied, reason} = GateService.wait(gate)
      assert reason =~ "requires file_path"
    end

    test "returns denied when file_path is empty string" do
      gate = %Gate{strategy: :file, file_path: "", timeout: 5}
      assert {:denied, reason} = GateService.wait(gate)
      assert reason =~ "requires file_path"
    end

    test "file created after gate starts is detected" do
      path = Path.join(@tmp_dir, "delayed_gate_#{:erlang.unique_integer([:positive])}")

      on_exit(fn -> File.rm(path) end)

      # Start gate in a separate process, then create file after short delay
      gate = %Gate{strategy: :file, file_path: path, timeout: 5}

      task =
        Task.async(fn ->
          GateService.wait(gate)
        end)

      # Create the file after a brief delay
      Process.sleep(500)
      File.write!(path, "approved")

      result = Task.await(task, 10_000)
      assert {:approved, _} = result
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # PROMPT STRATEGY
  # ─────────────────────────────────────────────────────────────────────────────

  describe "wait/1 with :prompt strategy" do
    test "returns denied in non-TTY environment" do
      # In test environment there is no TTY, so :io.columns() returns {:error, ...}
      gate = %Gate{strategy: :prompt, message: "Approve?", timeout: 5}
      assert {:denied, reason} = GateService.wait(gate)
      assert reason =~ "no TTY"
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # WEBHOOK STRATEGY (minimal — no HTTP mock)
  # ─────────────────────────────────────────────────────────────────────────────

  describe "wait/1 with :webhook strategy" do
    test "returns denied when webhook_url is nil" do
      gate = %Gate{strategy: :webhook, webhook_url: nil, timeout: 5}
      assert {:denied, reason} = GateService.wait(gate)
      assert reason =~ "requires webhook_url"
    end

    test "returns denied when webhook_url is empty string" do
      gate = %Gate{strategy: :webhook, webhook_url: "", timeout: 5}
      assert {:denied, reason} = GateService.wait(gate)
      assert reason =~ "requires webhook_url"
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # HELPERS
  # ─────────────────────────────────────────────────────────────────────────────

  defp make_temp_file(content) do
    path = Path.join(@tmp_dir, "gate_test_#{:erlang.unique_integer([:positive])}")
    File.write!(path, content)
    path
  end
end
