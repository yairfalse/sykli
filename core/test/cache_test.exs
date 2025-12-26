defmodule Sykli.CacheTest do
  use ExUnit.Case, async: false

  @test_cache_dir Path.expand("~/.sykli/cache_test")
  @test_workdir Path.expand("/tmp/sykli_cache_test_workdir")

  # Helper to create task struct
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
      mounts: Keyword.get(opts, :mounts, [])
    }
  end

  setup do
    # Clean up test directories
    File.rm_rf!(@test_cache_dir)
    File.rm_rf!(@test_workdir)
    File.mkdir_p!(@test_workdir)

    # Override cache directory for tests
    on_exit(fn ->
      File.rm_rf!(@test_cache_dir)
      File.rm_rf!(@test_workdir)
    end)

    :ok
  end

  describe "cache_key/2" do
    test "changes when command changes" do
      task1 = make_task("build", "go build -o app")
      task2 = make_task("build", "go build -o app2")

      key1 = Sykli.Cache.cache_key(task1, @test_workdir)
      key2 = Sykli.Cache.cache_key(task2, @test_workdir)

      assert key1 != key2
    end

    test "changes when task name changes" do
      task1 = make_task("build", "go build")
      task2 = make_task("compile", "go build")

      key1 = Sykli.Cache.cache_key(task1, @test_workdir)
      key2 = Sykli.Cache.cache_key(task2, @test_workdir)

      assert key1 != key2
    end

    test "changes when inputs change" do
      # Create test files
      File.write!(Path.join(@test_workdir, "main.go"), "package main")

      task = make_task("build", "go build", inputs: ["*.go"])
      key1 = Sykli.Cache.cache_key(task, @test_workdir)

      # Modify file
      File.write!(Path.join(@test_workdir, "main.go"), "package main // modified")

      key2 = Sykli.Cache.cache_key(task, @test_workdir)

      assert key1 != key2
    end

    test "same inputs produce same key" do
      File.write!(Path.join(@test_workdir, "main.go"), "package main")

      task = make_task("build", "go build", inputs: ["*.go"])
      key1 = Sykli.Cache.cache_key(task, @test_workdir)
      key2 = Sykli.Cache.cache_key(task, @test_workdir)

      assert key1 == key2
    end

    test "empty inputs produce consistent key" do
      task = make_task("test", "go test")
      key1 = Sykli.Cache.cache_key(task, @test_workdir)
      key2 = Sykli.Cache.cache_key(task, @test_workdir)

      assert key1 == key2
    end

    test "glob with no matches produces consistent key" do
      task = make_task("build", "go build", inputs: ["*.nonexistent"])
      key1 = Sykli.Cache.cache_key(task, @test_workdir)
      key2 = Sykli.Cache.cache_key(task, @test_workdir)

      assert key1 == key2
    end

    # v2 cache key tests
    test "changes when container changes" do
      task1 = make_task("build", "go build", container: "golang:1.21")
      task2 = make_task("build", "go build", container: "golang:1.22")

      key1 = Sykli.Cache.cache_key(task1, @test_workdir)
      key2 = Sykli.Cache.cache_key(task2, @test_workdir)

      assert key1 != key2
    end

    test "changes when task env changes" do
      task1 = make_task("build", "go build", env: %{"CGO_ENABLED" => "0"})
      task2 = make_task("build", "go build", env: %{"CGO_ENABLED" => "1"})

      key1 = Sykli.Cache.cache_key(task1, @test_workdir)
      key2 = Sykli.Cache.cache_key(task2, @test_workdir)

      assert key1 != key2
    end

    test "changes when mounts change" do
      task1 =
        make_task("build", "go build",
          mounts: [%{resource: "src:.", path: "/src", type: "directory"}]
        )

      task2 =
        make_task("build", "go build",
          mounts: [%{resource: "src:.", path: "/app", type: "directory"}]
        )

      key1 = Sykli.Cache.cache_key(task1, @test_workdir)
      key2 = Sykli.Cache.cache_key(task2, @test_workdir)

      assert key1 != key2
    end

    test "same v2 config produces same key" do
      task =
        make_task("build", "go build",
          container: "golang:1.21",
          env: %{"CGO_ENABLED" => "0"},
          mounts: [%{resource: "src:.", path: "/src", type: "directory"}]
        )

      key1 = Sykli.Cache.cache_key(task, @test_workdir)
      key2 = Sykli.Cache.cache_key(task, @test_workdir)

      assert key1 == key2
    end
  end

  describe "check/2" do
    test "returns miss when cache is empty" do
      Sykli.Cache.init()

      task = make_task("test", "go test")
      assert {:miss, _key} = Sykli.Cache.check(task, @test_workdir)
    end
  end

  describe "store and restore" do
    test "preserves file content" do
      Sykli.Cache.init()

      # Create output file
      output_path = Path.join(@test_workdir, "app")
      content = "#!/bin/sh\necho hello"
      File.write!(output_path, content)

      task = make_task("build", "echo build", outputs: ["app"])
      key = Sykli.Cache.cache_key(task, @test_workdir)
      assert :ok = Sykli.Cache.store(key, task, ["app"], 100, @test_workdir)

      # Delete the output
      File.rm!(output_path)
      refute File.exists?(output_path)

      # Restore
      assert :ok = Sykli.Cache.restore(key, @test_workdir)
      assert File.exists?(output_path)
      assert File.read!(output_path) == content
    end

    test "preserves file permissions" do
      Sykli.Cache.init()

      # Create executable output file
      output_path = Path.join(@test_workdir, "app")
      File.write!(output_path, "#!/bin/sh\necho hello")
      File.chmod!(output_path, 0o755)

      task = make_task("build", "echo build", outputs: ["app"])
      key = Sykli.Cache.cache_key(task, @test_workdir)
      assert :ok = Sykli.Cache.store(key, task, ["app"], 100, @test_workdir)

      # Delete and restore
      File.rm!(output_path)
      assert :ok = Sykli.Cache.restore(key, @test_workdir)

      # Check permissions
      {:ok, stat} = File.stat(output_path)
      # Check executable bit is preserved
      assert Bitwise.band(stat.mode, 0o111) != 0
    end

    test "identical files share blobs" do
      Sykli.Cache.init()
      Sykli.Cache.clean()

      # Create two identical files
      File.write!(Path.join(@test_workdir, "file1.txt"), "same content")
      File.write!(Path.join(@test_workdir, "file2.txt"), "same content")

      task1 = make_task("task1", "echo task1", outputs: ["file1.txt"])
      task2 = make_task("task2", "echo task2", outputs: ["file2.txt"])

      key1 = Sykli.Cache.cache_key(task1, @test_workdir)
      key2 = Sykli.Cache.cache_key(task2, @test_workdir)

      assert :ok = Sykli.Cache.store(key1, task1, ["file1.txt"], 100, @test_workdir)
      assert :ok = Sykli.Cache.store(key2, task2, ["file2.txt"], 100, @test_workdir)

      # Check that only one blob exists (deduplication)
      blobs_dir = Path.join(Sykli.Cache.cache_dir(), "blobs")
      blob_files = Path.wildcard(Path.join(blobs_dir, "*"))

      # Should have exactly 1 blob for the identical content
      assert length(blob_files) == 1
    end

    test "handles missing output files gracefully" do
      Sykli.Cache.init()

      task = make_task("build", "echo build", outputs: ["nonexistent.txt"])
      key = Sykli.Cache.cache_key(task, @test_workdir)

      # Should not crash, but won't store any outputs
      assert :ok = Sykli.Cache.store(key, task, ["nonexistent.txt"], 100, @test_workdir)
    end

    test "handles directory outputs" do
      Sykli.Cache.init()

      # Create a directory with files
      dir_path = Path.join(@test_workdir, "dist")
      File.mkdir_p!(dir_path)
      File.write!(Path.join(dir_path, "index.js"), "console.log('hello')")
      File.write!(Path.join(dir_path, "style.css"), "body { color: red }")

      task = make_task("build", "echo build", outputs: ["dist"])
      key = Sykli.Cache.cache_key(task, @test_workdir)
      assert :ok = Sykli.Cache.store(key, task, ["dist"], 100, @test_workdir)

      # Delete and restore
      File.rm_rf!(dir_path)
      refute File.exists?(dir_path)

      assert :ok = Sykli.Cache.restore(key, @test_workdir)

      # Check files are restored
      assert File.exists?(Path.join(dir_path, "index.js"))
      assert File.exists?(Path.join(dir_path, "style.css"))
    end
  end

  describe "corrupted cache" do
    test "handles corrupted meta file" do
      Sykli.Cache.init()

      # Create a corrupted meta file
      meta_dir = Path.join(Sykli.Cache.cache_dir(), "meta")
      File.mkdir_p!(meta_dir)
      File.write!(Path.join(meta_dir, "corrupted.json"), "not valid json")

      # Should treat as miss
      task = make_task("test", "echo test")
      assert {:miss, _} = Sykli.Cache.check(task, @test_workdir)
    end

    test "handles missing blob for valid meta" do
      Sykli.Cache.init()

      # Create output file and cache it
      output_path = Path.join(@test_workdir, "app")
      File.write!(output_path, "content")

      task = make_task("build", "echo build", outputs: ["app"])
      key = Sykli.Cache.cache_key(task, @test_workdir)
      assert :ok = Sykli.Cache.store(key, task, ["app"], 100, @test_workdir)

      # Delete the blob
      blobs_dir = Path.join(Sykli.Cache.cache_dir(), "blobs")
      Path.wildcard(Path.join(blobs_dir, "*")) |> Enum.each(&File.rm!/1)

      # Should treat as miss and clean up meta
      assert {:miss, _} = Sykli.Cache.check(task, @test_workdir)
    end
  end

  describe "stats/0" do
    test "returns correct statistics" do
      Sykli.Cache.init()
      Sykli.Cache.clean()

      # Create and cache some outputs
      File.write!(Path.join(@test_workdir, "file1.txt"), "content 1")
      File.write!(Path.join(@test_workdir, "file2.txt"), "different content 2")

      task1 = make_task("task1", "echo 1", outputs: ["file1.txt"])
      task2 = make_task("task2", "echo 2", outputs: ["file2.txt"])

      key1 = Sykli.Cache.cache_key(task1, @test_workdir)
      key2 = Sykli.Cache.cache_key(task2, @test_workdir)

      Sykli.Cache.store(key1, task1, ["file1.txt"], 100, @test_workdir)
      Sykli.Cache.store(key2, task2, ["file2.txt"], 200, @test_workdir)

      stats = Sykli.Cache.stats()

      assert stats.meta_count == 2
      assert stats.blob_count == 2
      assert stats.total_size > 0
    end
  end

  describe "clean/0" do
    test "removes all cache entries" do
      Sykli.Cache.init()

      # Create some cache entries
      File.write!(Path.join(@test_workdir, "app"), "content")

      task = make_task("build", "echo", outputs: ["app"])
      key = Sykli.Cache.cache_key(task, @test_workdir)
      Sykli.Cache.store(key, task, ["app"], 100, @test_workdir)

      # Verify cache exists
      stats_before = Sykli.Cache.stats()
      assert stats_before.meta_count > 0

      # Clean
      assert :ok = Sykli.Cache.clean()

      # Verify cache is empty
      stats_after = Sykli.Cache.stats()
      assert stats_after.meta_count == 0
      assert stats_after.blob_count == 0
    end
  end

  describe "check_detailed/2" do
    test "returns :no_cache when cache is empty" do
      Sykli.Cache.init()
      Sykli.Cache.clean()

      task = make_task("test", "echo test")
      assert {:miss, _key, :no_cache} = Sykli.Cache.check_detailed(task, @test_workdir)
    end

    test "returns :hit when cache is valid" do
      Sykli.Cache.init()
      Sykli.Cache.clean()

      File.write!(Path.join(@test_workdir, "out.txt"), "output")

      task = make_task("test", "echo test", outputs: ["out.txt"])
      key = Sykli.Cache.cache_key(task, @test_workdir)
      Sykli.Cache.store(key, task, ["out.txt"], 100, @test_workdir)

      assert {:hit, ^key} = Sykli.Cache.check_detailed(task, @test_workdir)
    end

    test "returns :command_changed when command differs" do
      Sykli.Cache.init()
      Sykli.Cache.clean()

      File.write!(Path.join(@test_workdir, "out.txt"), "output")

      # Store with original command
      task1 = make_task("build", "echo v1", outputs: ["out.txt"])
      key1 = Sykli.Cache.cache_key(task1, @test_workdir)
      Sykli.Cache.store(key1, task1, ["out.txt"], 100, @test_workdir)

      # Check with different command
      task2 = make_task("build", "echo v2", outputs: ["out.txt"])
      assert {:miss, _key, :command_changed} = Sykli.Cache.check_detailed(task2, @test_workdir)
    end

    test "returns :inputs_changed when input files differ" do
      Sykli.Cache.init()
      Sykli.Cache.clean()

      File.write!(Path.join(@test_workdir, "main.go"), "v1")
      File.write!(Path.join(@test_workdir, "out.txt"), "output")

      task = make_task("build", "go build", inputs: ["*.go"], outputs: ["out.txt"])
      key = Sykli.Cache.cache_key(task, @test_workdir)
      Sykli.Cache.store(key, task, ["out.txt"], 100, @test_workdir)

      # Modify input file
      File.write!(Path.join(@test_workdir, "main.go"), "v2")

      assert {:miss, _key, :inputs_changed} = Sykli.Cache.check_detailed(task, @test_workdir)
    end

    test "returns :container_changed when container differs" do
      Sykli.Cache.init()
      Sykli.Cache.clean()

      File.write!(Path.join(@test_workdir, "out.txt"), "output")

      task1 = make_task("build", "go build", container: "golang:1.21", outputs: ["out.txt"])
      key1 = Sykli.Cache.cache_key(task1, @test_workdir)
      Sykli.Cache.store(key1, task1, ["out.txt"], 100, @test_workdir)

      task2 = make_task("build", "go build", container: "golang:1.22", outputs: ["out.txt"])
      assert {:miss, _key, :container_changed} = Sykli.Cache.check_detailed(task2, @test_workdir)
    end

    test "returns :env_changed when task env differs" do
      Sykli.Cache.init()
      Sykli.Cache.clean()

      File.write!(Path.join(@test_workdir, "out.txt"), "output")

      task1 = make_task("build", "go build", env: %{"CGO_ENABLED" => "0"}, outputs: ["out.txt"])
      key1 = Sykli.Cache.cache_key(task1, @test_workdir)
      Sykli.Cache.store(key1, task1, ["out.txt"], 100, @test_workdir)

      task2 = make_task("build", "go build", env: %{"CGO_ENABLED" => "1"}, outputs: ["out.txt"])
      assert {:miss, _key, :env_changed} = Sykli.Cache.check_detailed(task2, @test_workdir)
    end

    test "returns :mounts_changed when task mounts differ" do
      Sykli.Cache.init()
      Sykli.Cache.clean()

      File.write!(Path.join(@test_workdir, "out.txt"), "output")

      mount1 = %{resource: "src:.", path: "/app", type: :directory}
      task1 = make_task("build", "go build", mounts: [mount1], outputs: ["out.txt"])
      key1 = Sykli.Cache.cache_key(task1, @test_workdir)
      Sykli.Cache.store(key1, task1, ["out.txt"], 100, @test_workdir)

      mount2 = %{resource: "src:./src", path: "/app", type: :directory}
      task2 = make_task("build", "go build", mounts: [mount2], outputs: ["out.txt"])
      assert {:miss, _key, :mounts_changed} = Sykli.Cache.check_detailed(task2, @test_workdir)
    end

    test "returns :corrupted when meta file is invalid" do
      Sykli.Cache.init()
      Sykli.Cache.clean()

      # Create a corrupted meta file with same key format
      task = make_task("test", "echo test")
      key = Sykli.Cache.cache_key(task, @test_workdir)
      meta_dir = Path.join(Sykli.Cache.cache_dir(), "meta")
      File.write!(Path.join(meta_dir, "#{key}.json"), "not json")

      assert {:miss, ^key, :corrupted} = Sykli.Cache.check_detailed(task, @test_workdir)
    end

    test "returns :blobs_missing when output blobs are gone" do
      Sykli.Cache.init()
      Sykli.Cache.clean()

      File.write!(Path.join(@test_workdir, "out.txt"), "output")

      task = make_task("build", "echo build", outputs: ["out.txt"])
      key = Sykli.Cache.cache_key(task, @test_workdir)
      Sykli.Cache.store(key, task, ["out.txt"], 100, @test_workdir)

      # Delete blobs
      blobs_dir = Path.join(Sykli.Cache.cache_dir(), "blobs")
      Path.wildcard(Path.join(blobs_dir, "*")) |> Enum.each(&File.rm!/1)

      assert {:miss, ^key, :blobs_missing} = Sykli.Cache.check_detailed(task, @test_workdir)
    end
  end

  describe "clean_older_than/1" do
    test "removes old entries and keeps recent ones" do
      Sykli.Cache.init()
      Sykli.Cache.clean()

      # Create cache entries
      File.write!(Path.join(@test_workdir, "old.txt"), "old")
      File.write!(Path.join(@test_workdir, "new.txt"), "new")

      task_old = make_task("old", "echo old", outputs: ["old.txt"])
      task_new = make_task("new", "echo new", outputs: ["new.txt"])

      key_old = Sykli.Cache.cache_key(task_old, @test_workdir)
      key_new = Sykli.Cache.cache_key(task_new, @test_workdir)

      Sykli.Cache.store(key_old, task_old, ["old.txt"], 100, @test_workdir)
      Sykli.Cache.store(key_new, task_new, ["new.txt"], 100, @test_workdir)

      # Manually modify the old entry's timestamp
      meta_dir = Path.join(Sykli.Cache.cache_dir(), "meta")
      old_meta_path = Path.join(meta_dir, "#{key_old}.json")

      {:ok, content} = File.read(old_meta_path)
      {:ok, meta} = Jason.decode(content)

      old_time =
        DateTime.utc_now()
        |> DateTime.add(-86400 * 10, :second)
        |> DateTime.to_iso8601()

      updated_meta = Map.put(meta, "cached_at", old_time)
      File.write!(old_meta_path, Jason.encode!(updated_meta))

      # Clean entries older than 7 days
      result = Sykli.Cache.clean_older_than(7 * 86400)

      assert result.meta_deleted == 1

      # New entry should still exist
      stats = Sykli.Cache.stats()
      assert stats.meta_count == 1
    end
  end
end
