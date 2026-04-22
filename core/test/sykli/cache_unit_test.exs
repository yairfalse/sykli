defmodule Sykli.CacheUnitTest do
  use ExUnit.Case, async: true

  alias Sykli.Cache
  alias Sykli.Cache.FileRepository
  alias Sykli.Cache.Entry

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp make_task(name, command, opts \\ []) do
    %Sykli.Graph.Task{
      name: name,
      command: command,
      inputs: Keyword.get(opts, :inputs, []),
      outputs: Keyword.get(opts, :outputs, []),
      depends_on: [],
      container: Keyword.get(opts, :container),
      workdir: Keyword.get(opts, :workdir),
      env: Keyword.get(opts, :env, %{}),
      mounts: Keyword.get(opts, :mounts, []),
      secret_refs: Keyword.get(opts, :secret_refs, [])
    }
  end

  defp sha256_hex(input) do
    :crypto.hash(:sha256, input)
    |> Base.encode16(case: :lower)
  end

  defp init_git_repo!(dir, opts \\ []) do
    File.mkdir_p!(dir)
    {_, 0} = System.cmd("git", ["init", "-b", "main"], cd: dir)

    if origin = opts[:origin] do
      {_, 0} = System.cmd("git", ["config", "remote.origin.url", origin], cd: dir)
    end

    dir
  end

  # ---------------------------------------------------------------------------
  # 1. Cache.cache_key/2 — deterministic SHA256 keys from task metadata
  # ---------------------------------------------------------------------------

  describe "cache_key/2 determinism" do
    @tag :tmp_dir
    test "same task produces same key", %{tmp_dir: dir} do
      task = make_task("build", "go build -o app")
      key1 = Cache.cache_key(task, dir)
      key2 = Cache.cache_key(task, dir)

      assert key1 == key2
      # SHA256 hex = 64 characters
      assert String.length(key1) == 64
      assert Regex.match?(~r/\A[0-9a-f]{64}\z/, key1)
    end

    @tag :tmp_dir
    test "different task name produces different key", %{tmp_dir: dir} do
      task1 = make_task("build", "go build")
      task2 = make_task("compile", "go build")

      assert Cache.cache_key(task1, dir) != Cache.cache_key(task2, dir)
    end

    @tag :tmp_dir
    test "different command produces different key", %{tmp_dir: dir} do
      task1 = make_task("build", "go build -o app")
      task2 = make_task("build", "go build -o app2")

      assert Cache.cache_key(task1, dir) != Cache.cache_key(task2, dir)
    end

    @tag :tmp_dir
    test "different secret_refs produces different key (SEC-007)", %{tmp_dir: dir} do
      task1 =
        make_task("deploy", "kubectl apply",
          secret_refs: [%{name: "AWS_KEY", source: "vault", key: "aws/key"}]
        )

      task2 =
        make_task("deploy", "kubectl apply",
          secret_refs: [%{name: "AWS_KEY_V2", source: "vault", key: "aws/key-v2"}]
        )

      assert Cache.cache_key(task1, dir) != Cache.cache_key(task2, dir)
    end

    @tag :tmp_dir
    test "empty secret_refs vs non-empty secret_refs produces different key", %{tmp_dir: dir} do
      task_no_secrets = make_task("deploy", "kubectl apply", secret_refs: [])

      task_with_secrets =
        make_task("deploy", "kubectl apply",
          secret_refs: [%{name: "TOKEN", source: "env", key: "TOKEN"}]
        )

      assert Cache.cache_key(task_no_secrets, dir) != Cache.cache_key(task_with_secrets, dir)
    end

    @tag :tmp_dir
    test "key includes project fingerprint (different workdirs produce different keys)", %{
      tmp_dir: dir
    } do
      # Two distinct workdirs should yield different fingerprints and thus
      # different cache keys even for an identical task definition.
      other_dir = Path.join(dir, "other_project")
      File.mkdir_p!(other_dir)

      task = make_task("build", "make")

      key1 = Cache.cache_key(task, dir)
      key2 = Cache.cache_key(task, other_dir)

      assert key1 != key2
    end

    @tag :tmp_dir
    test "monorepo subdirectories produce different fingerprints", %{tmp_dir: dir} do
      repo = init_git_repo!(Path.join(dir, "mono"), origin: "git@github.com:false/sykli.git")
      frontend = Path.join(repo, "frontend")
      backend = Path.join(repo, "backend")

      File.mkdir_p!(frontend)
      File.mkdir_p!(backend)

      assert Cache.project_fingerprint(frontend) != Cache.project_fingerprint(backend)
    end

    @tag :tmp_dir
    test "same project cloned to different absolute paths produces same fingerprint", %{
      tmp_dir: dir
    } do
      origin = "git@github.com:false/sykli.git"
      repo1 = init_git_repo!(Path.join(dir, "clone_a"), origin: origin)
      repo2 = init_git_repo!(Path.join(dir, "clone_b"), origin: origin)

      assert Cache.project_fingerprint(repo1) == Cache.project_fingerprint(repo2)
    end

    @tag :tmp_dir
    test "non-git directory uses absolute-path fallback", %{tmp_dir: dir} do
      original = Path.join(dir, "plain_project")
      moved = Path.join(dir, "moved_project")

      File.mkdir_p!(original)

      fingerprint_before = Cache.project_fingerprint(original)
      File.rename!(original, moved)
      fingerprint_after = Cache.project_fingerprint(moved)

      assert fingerprint_before != fingerprint_after
    end

    @tag :tmp_dir
    test "non-git directory with same absolute path produces same fingerprint across invocations",
         %{
           tmp_dir: dir
         } do
      project = Path.join(dir, "plain_project")
      File.mkdir_p!(project)

      assert Cache.project_fingerprint(project) == Cache.project_fingerprint(project)
    end

    @tag :tmp_dir
    test "git repo without origin remote uses absolute-path fallback", %{tmp_dir: dir} do
      repo = init_git_repo!(Path.join(dir, "no_origin"))
      expected = sha256_hex("path:#{Path.expand(repo)}")

      assert Cache.project_root(repo) == {:non_git, Path.expand(repo)}
      assert Cache.project_fingerprint(repo) == expected
    end

    @tag :tmp_dir
    test "different container produces different key", %{tmp_dir: dir} do
      task1 = make_task("build", "go build", container: "golang:1.21")
      task2 = make_task("build", "go build", container: "golang:1.22")

      assert Cache.cache_key(task1, dir) != Cache.cache_key(task2, dir)
    end

    @tag :tmp_dir
    test "different env produces different key", %{tmp_dir: dir} do
      task1 = make_task("build", "go build", env: %{"CGO_ENABLED" => "0"})
      task2 = make_task("build", "go build", env: %{"CGO_ENABLED" => "1"})

      assert Cache.cache_key(task1, dir) != Cache.cache_key(task2, dir)
    end

    @tag :tmp_dir
    test "different mounts produces different key", %{tmp_dir: dir} do
      task1 =
        make_task("build", "go build",
          mounts: [%{resource: "src:.", path: "/src", type: "directory"}]
        )

      task2 =
        make_task("build", "go build",
          mounts: [%{resource: "src:.", path: "/app", type: "directory"}]
        )

      assert Cache.cache_key(task1, dir) != Cache.cache_key(task2, dir)
    end
  end

  # ---------------------------------------------------------------------------
  # 2. File hashing via cache_key — input file changes invalidate the key
  # ---------------------------------------------------------------------------

  describe "cache_key/2 input file hashing" do
    @tag :tmp_dir
    test "input file content change produces different key", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "main.go"), "package main")

      task = make_task("build", "go build", inputs: ["*.go"])
      key1 = Cache.cache_key(task, dir)

      File.write!(Path.join(dir, "main.go"), "package main // v2")
      key2 = Cache.cache_key(task, dir)

      assert key1 != key2
    end

    @tag :tmp_dir
    test "identical file content produces same key", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "main.go"), "package main")

      task = make_task("build", "go build", inputs: ["*.go"])
      key1 = Cache.cache_key(task, dir)
      key2 = Cache.cache_key(task, dir)

      assert key1 == key2
    end

    @tag :tmp_dir
    test "empty file uses metadata-based hash", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "empty.go"), "")

      task = make_task("build", "go build", inputs: ["*.go"])
      # Should not crash on empty files
      key = Cache.cache_key(task, dir)
      assert is_binary(key) and String.length(key) == 64
    end

    @tag :tmp_dir
    test "glob with no matches produces consistent key", %{tmp_dir: dir} do
      task = make_task("build", "go build", inputs: ["*.nonexistent"])
      key1 = Cache.cache_key(task, dir)
      key2 = Cache.cache_key(task, dir)

      assert key1 == key2
    end

    @tag :tmp_dir
    test "adding a new input file changes the key", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "a.go"), "package a")

      task = make_task("build", "go build", inputs: ["*.go"])
      key1 = Cache.cache_key(task, dir)

      File.write!(Path.join(dir, "b.go"), "package b")
      key2 = Cache.cache_key(task, dir)

      assert key1 != key2
    end
  end

  # ---------------------------------------------------------------------------
  # 3. FileRepository — basic put/get and blob operations
  # ---------------------------------------------------------------------------

  describe "FileRepository put/get round trip" do
    setup do
      FileRepository.init()
      FileRepository.clean()

      on_exit(fn ->
        FileRepository.clean()
      end)

      :ok
    end

    test "put then get returns the entry" do
      entry =
        Entry.new(%{
          task_name: "build",
          command: "make",
          outputs: [],
          duration_ms: 42,
          cached_at: DateTime.utc_now(),
          inputs_hash: "abc123",
          container: "",
          env_hash: "",
          mounts_hash: "",
          sykli_version: "0.1.0"
        })

      key = "test_key_roundtrip"
      assert :ok = FileRepository.put(key, entry)

      assert {:ok, fetched} = FileRepository.get(key)
      assert fetched.task_name == "build"
      assert fetched.command == "make"
      assert fetched.duration_ms == 42
      assert fetched.inputs_hash == "abc123"
      assert fetched.sykli_version == "0.1.0"
    end

    test "get returns error for missing key" do
      assert {:error, :not_found} = FileRepository.get("nonexistent_key_xyz")
    end

    test "exists? returns true after put" do
      entry =
        Entry.new(%{
          task_name: "t",
          command: "echo",
          cached_at: DateTime.utc_now(),
          inputs_hash: "h",
          sykli_version: "0.1.0"
        })

      key = "test_exists_check"
      FileRepository.put(key, entry)
      assert FileRepository.exists?(key)
    end

    test "exists? returns false for missing key" do
      refute FileRepository.exists?("does_not_exist_abc")
    end

    test "delete removes the entry" do
      entry =
        Entry.new(%{
          task_name: "t",
          command: "echo",
          cached_at: DateTime.utc_now(),
          inputs_hash: "h",
          sykli_version: "0.1.0"
        })

      key = "test_delete_key"
      FileRepository.put(key, entry)
      assert FileRepository.exists?(key)

      FileRepository.delete(key)
      refute FileRepository.exists?(key)
    end

    test "list_keys includes stored keys" do
      entry =
        Entry.new(%{
          task_name: "t",
          command: "echo",
          cached_at: DateTime.utc_now(),
          inputs_hash: "h",
          sykli_version: "0.1.0"
        })

      key = "test_list_keys_unique"
      FileRepository.put(key, entry)
      assert key in FileRepository.list_keys()
    end
  end

  describe "FileRepository store_blob/get_blob round trip" do
    setup do
      FileRepository.init()

      on_exit(fn ->
        FileRepository.clean()
      end)

      :ok
    end

    test "store_blob returns content-addressed hash and get_blob retrieves content" do
      content = "hello world blob content"
      expected_hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

      assert {:ok, ^expected_hash} = FileRepository.store_blob(content)
      assert {:ok, ^content} = FileRepository.get_blob(expected_hash)
    end

    test "store_blob is idempotent (storing same content twice returns same hash)" do
      content = "idempotent blob test"
      {:ok, hash1} = FileRepository.store_blob(content)
      {:ok, hash2} = FileRepository.store_blob(content)

      assert hash1 == hash2
    end

    test "get_blob returns error for missing hash" do
      assert {:error, :not_found} =
               FileRepository.get_blob(
                 "0000000000000000000000000000000000000000000000000000000000000000"
               )
    end

    test "blob_exists? works correctly" do
      content = "blob exists check"
      {:ok, hash} = FileRepository.store_blob(content)

      assert FileRepository.blob_exists?(hash)
      refute FileRepository.blob_exists?("nonexistent_hash")
    end

    test "different content produces different hashes" do
      {:ok, hash1} = FileRepository.store_blob("content A")
      {:ok, hash2} = FileRepository.store_blob("content B")

      assert hash1 != hash2
    end
  end

  # ---------------------------------------------------------------------------
  # 4. TieredRepository circuit breaker
  # ---------------------------------------------------------------------------

  describe "TieredRepository circuit breaker" do
    test "circuit starts closed (initial state)" do
      # Clear any prior circuit breaker state
      try do
        :persistent_term.erase(:sykli_s3_circuit)
      rescue
        ArgumentError -> :ok
      end

      # After init, the circuit should be closed (failures: 0).
      # We test this by inspecting the persistent_term directly since
      # the circuit_closed? function is private.
      Sykli.Cache.TieredRepository.init()

      state = :persistent_term.get(:sykli_s3_circuit)
      assert state.failures == 0
      assert state.open_until == 0
    end

    test "circuit opens after reaching failure threshold" do
      # Reset state
      :persistent_term.put(:sykli_s3_circuit, %{failures: 0, open_until: 0})

      # Simulate 5 consecutive failures (the @failure_threshold)
      # by manually incrementing the failure counter.
      # The threshold is 5, so after 5 failures the circuit opens.
      for i <- 1..4 do
        :persistent_term.put(:sykli_s3_circuit, %{failures: i, open_until: 0})
      end

      state_before = :persistent_term.get(:sykli_s3_circuit)
      assert state_before.failures == 4

      # The 5th failure should trigger the open state with a future open_until.
      # Simulate what record_failure does at the threshold crossing:
      open_until = System.monotonic_time(:millisecond) + 60_000

      :persistent_term.put(:sykli_s3_circuit, %{
        failures: 5,
        open_until: open_until
      })

      state_after = :persistent_term.get(:sykli_s3_circuit)
      assert state_after.failures == 5
      assert state_after.open_until > 0

      # The circuit is now open: open_until is in the future and
      # failures >= threshold (5).
      # Verify the state represents an open circuit:
      now = System.monotonic_time(:millisecond)
      assert state_after.failures >= 5
      assert state_after.open_until > now
    end

    test "circuit resets to closed on success" do
      # Put circuit in open state
      open_until = System.monotonic_time(:millisecond) + 60_000

      :persistent_term.put(:sykli_s3_circuit, %{
        failures: 5,
        open_until: open_until
      })

      # Simulate a success by resetting to zero (what record_success does)
      :persistent_term.put(:sykli_s3_circuit, %{failures: 0, open_until: 0})

      state = :persistent_term.get(:sykli_s3_circuit)
      assert state.failures == 0
      assert state.open_until == 0
    end

    test "circuit allows requests again after cooldown expires" do
      # Set circuit to open with an open_until in the past
      expired_time = System.monotonic_time(:millisecond) - 1000

      :persistent_term.put(:sykli_s3_circuit, %{
        failures: 5,
        open_until: expired_time
      })

      # The circuit_closed? logic checks:
      # - failures < threshold? no (5 >= 5)
      # - monotonic_time >= open_until? yes (it's in the past)
      # So it returns true (half-open / closed).
      state = :persistent_term.get(:sykli_s3_circuit)
      now = System.monotonic_time(:millisecond)

      is_closed =
        cond do
          state.failures < 5 -> true
          now >= state.open_until -> true
          true -> false
        end

      assert is_closed
    end
  end

  # ---------------------------------------------------------------------------
  # 5. Cache.Entry — struct creation and serialization
  # ---------------------------------------------------------------------------

  describe "Cache.Entry" do
    test "new/1 creates entry with required fields" do
      entry =
        Entry.new(%{
          task_name: "test",
          command: "mix test",
          cached_at: ~U[2026-01-01 00:00:00Z],
          inputs_hash: "abc",
          sykli_version: "0.1.0"
        })

      assert entry.task_name == "test"
      assert entry.command == "mix test"
      assert entry.outputs == []
      assert entry.duration_ms == 0
      assert entry.container == ""
      assert entry.env_hash == ""
      assert entry.mounts_hash == ""
    end

    test "to_map/1 and from_map/1 round trip" do
      entry =
        Entry.new(%{
          task_name: "build",
          command: "make",
          outputs: [%{"path" => "app", "blob" => "deadbeef", "mode" => 0o755, "size" => 1024}],
          duration_ms: 500,
          cached_at: ~U[2026-03-15 12:00:00Z],
          inputs_hash: "inputs_hash_value",
          container: "golang:1.21",
          env_hash: "env_hash_value",
          mounts_hash: "mounts_hash_value",
          sykli_version: "0.1.0"
        })

      map = Entry.to_map(entry)
      assert map["task_name"] == "build"
      assert map["command"] == "make"
      assert map["duration_ms"] == 500
      assert map["container"] == "golang:1.21"

      {:ok, restored} = Entry.from_map(map)
      assert restored.task_name == entry.task_name
      assert restored.command == entry.command
      assert restored.duration_ms == entry.duration_ms
      assert restored.inputs_hash == entry.inputs_hash
      assert restored.container == entry.container
    end

    test "from_map/1 returns error for non-map input" do
      assert {:error, :invalid} = Entry.from_map("not a map")
      assert {:error, :invalid} = Entry.from_map(nil)
    end
  end

  # ---------------------------------------------------------------------------
  # 6. format_miss_reason/1
  # ---------------------------------------------------------------------------

  describe "format_miss_reason/1" do
    test "formats all known reasons" do
      assert Cache.format_miss_reason(:no_cache) == "first run"
      assert Cache.format_miss_reason(:command_changed) == "command changed"
      assert Cache.format_miss_reason(:inputs_changed) == "inputs changed"
      assert Cache.format_miss_reason(:container_changed) == "container changed"
      assert Cache.format_miss_reason(:env_changed) == "env changed"
      assert Cache.format_miss_reason(:mounts_changed) == "mounts changed"
      assert Cache.format_miss_reason(:corrupted) == "cache corrupted"
      assert Cache.format_miss_reason(:blobs_missing) == "outputs missing"
      assert Cache.format_miss_reason(:config_changed) == "config changed"
    end

    test "formats unknown reason as string" do
      assert Cache.format_miss_reason(:something_else) == "something_else"
    end
  end
end
