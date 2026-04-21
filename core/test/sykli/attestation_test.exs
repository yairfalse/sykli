defmodule Sykli.AttestationTest do
  use ExUnit.Case, async: true

  alias Sykli.Attestation
  alias Sykli.Attestation.Envelope
  alias Sykli.Attestation.Signer.HMAC
  alias Sykli.Occurrence
  alias Sykli.Occurrence.GitContext

  @tmp_dir System.tmp_dir!()

  setup do
    test_dir = Path.join(@tmp_dir, "attestation_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(test_dir)
    on_exit(fn -> File.rm_rf!(test_dir) end)
    {:ok, workdir: test_dir}
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # generate/3 — per-run attestation
  # ─────────────────────────────────────────────────────────────────────────────

  describe "generate/3" do
    test "returns {:error, :no_subjects} when passing run has no outputs", %{workdir: workdir} do
      occ = build_occurrence_with_data()
      graph = parse_graph!([%{"name" => "test", "command" => "mix test"}])

      assert {:error, :no_subjects} = Attestation.generate(occ, graph, workdir)
    end

    test "produces valid in-toto Statement v1 structure", %{workdir: workdir} do
      occ = build_occurrence_with_data()
      graph = parse_graph!([%{"name" => "build", "command" => "make", "outputs" => ["out/app"]}])
      setup_cache_entry(graph, "build", workdir)

      assert {:ok, att} = Attestation.generate(occ, graph, workdir)
      assert att["_type"] == "https://in-toto.io/Statement/v1"
      assert att["predicateType"] == "https://slsa.dev/provenance/v1"
      assert length(att["subject"]) > 0
    end

    test "subjects have name and sha256 digest", %{workdir: workdir} do
      occ = build_occurrence_with_data()
      graph = parse_graph!([%{"name" => "build", "command" => "make", "outputs" => ["out/app"]}])
      setup_cache_entry(graph, "build", workdir)

      assert {:ok, att} = Attestation.generate(occ, graph, workdir)
      subject = hd(att["subject"])
      assert is_binary(subject["name"])
      assert String.length(subject["digest"]["sha256"]) == 64
    end

    test "falls back to hashing declared output files when no cache entry exists", %{
      workdir: workdir
    } do
      occ = build_occurrence_with_data()
      graph = parse_graph!([%{"name" => "build", "command" => "make", "outputs" => ["out/app"]}])

      out_dir = Path.join(workdir, "out")
      File.mkdir_p!(out_dir)
      File.write!(Path.join(out_dir, "app"), "binary content")

      assert {:ok, att} = Attestation.generate(occ, graph, workdir)

      assert att["subject"] == [
               %{
                 "name" => "out/app",
                 "digest" => %{
                   "sha256" => "93a0b24644f2e0fd11d6b422c90275c482b0cc20be4a4e3f62148ed2932b4792"
                 }
               }
             ]
    end

    test "resolvedDependencies includes git source with branch annotation", %{workdir: workdir} do
      occ = build_occurrence_with_data()
      graph = parse_graph!([%{"name" => "build", "command" => "make", "outputs" => ["out/app"]}])
      setup_cache_entry(graph, "build", workdir)

      assert {:ok, att} = Attestation.generate(occ, graph, workdir)
      deps = att["predicate"]["buildDefinition"]["resolvedDependencies"]
      git_dep = Enum.find(deps, &String.starts_with?(&1["uri"] || "", "git+"))
      assert git_dep["digest"]["gitCommit"] == "abc123def456789"
      assert git_dep["annotations"]["branch"] == "main"
    end

    test "resolvedDependencies includes container images", %{workdir: workdir} do
      occ = build_occurrence_with_data()

      graph =
        parse_graph!([
          %{
            "name" => "build",
            "command" => "make",
            "container" => "golang:1.21",
            "outputs" => ["out/app"]
          }
        ])

      setup_cache_entry(graph, "build", workdir)

      assert {:ok, att} = Attestation.generate(occ, graph, workdir)
      deps = att["predicate"]["buildDefinition"]["resolvedDependencies"]
      assert Enum.any?(deps, &(&1["uri"] == "pkg:docker/golang:1.21"))
    end

    test "metadata includes outcome", %{workdir: workdir} do
      occ = build_occurrence_with_data()
      graph = parse_graph!([%{"name" => "build", "command" => "make", "outputs" => ["out/app"]}])
      setup_cache_entry(graph, "build", workdir)

      assert {:ok, att} = Attestation.generate(occ, graph, workdir)
      assert att["predicate"]["runDetails"]["metadata"]["outcome"] == "success"
    end

    test "finishedOn computed from history duration", %{workdir: workdir} do
      occ =
        build_occurrence_with_data()
        |> Map.put(:history, %{"duration_ms" => 5000, "steps" => []})

      graph = parse_graph!([%{"name" => "build", "command" => "make", "outputs" => ["out/app"]}])
      setup_cache_entry(graph, "build", workdir)

      assert {:ok, att} = Attestation.generate(occ, graph, workdir)
      metadata = att["predicate"]["runDetails"]["metadata"]
      assert metadata["finishedOn"] != metadata["startedOn"]
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # generate/3 — failed runs
  # ─────────────────────────────────────────────────────────────────────────────

  describe "generate/3 — failed runs" do
    test "allows empty subjects for failed runs", %{workdir: workdir} do
      occ = build_failed_occurrence()
      graph = parse_graph!([%{"name" => "build", "command" => "make"}])

      assert {:ok, att} = Attestation.generate(occ, graph, workdir)
      assert att["subject"] == []
      assert att["predicate"]["runDetails"]["metadata"]["outcome"] == "failure"
    end

    test "includes subjects when failed run has cached artifacts", %{workdir: workdir} do
      occ = build_failed_occurrence()
      graph = parse_graph!([%{"name" => "build", "command" => "make", "outputs" => ["out/app"]}])
      setup_cache_entry(graph, "build", workdir)

      assert {:ok, att} = Attestation.generate(occ, graph, workdir)
      assert length(att["subject"]) > 0
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # generate_per_task/3
  # ─────────────────────────────────────────────────────────────────────────────

  describe "generate_per_task/3" do
    test "returns empty list when no tasks have outputs", %{workdir: workdir} do
      occ = build_occurrence_with_data()
      graph = parse_graph!([%{"name" => "test", "command" => "mix test"}])

      assert [] = Attestation.generate_per_task(occ, graph, workdir)
    end

    test "returns one attestation per task with outputs", %{workdir: workdir} do
      occ = build_occurrence_with_data()

      graph =
        parse_graph!([
          %{"name" => "lint", "command" => "mix lint"},
          %{"name" => "build", "command" => "make", "outputs" => ["out/app"]}
        ])

      setup_cache_entry(graph, "build", workdir)

      result = Attestation.generate_per_task(occ, graph, workdir)
      assert length(result) == 1
      [{name, att}] = result
      assert name == "build"
      assert att["_type"] == "https://in-toto.io/Statement/v1"
      assert length(att["subject"]) > 0
    end

    test "per-task attestation only includes that task in externalParameters", %{workdir: workdir} do
      occ = build_occurrence_with_data()

      graph =
        parse_graph!([
          %{"name" => "lint", "command" => "mix lint"},
          %{"name" => "build", "command" => "make", "outputs" => ["out/app"]}
        ])

      setup_cache_entry(graph, "build", workdir)

      [{_name, att}] = Attestation.generate_per_task(occ, graph, workdir)
      tasks = att["predicate"]["buildDefinition"]["externalParameters"]["tasks"]
      assert length(tasks) == 1
      assert hd(tasks)["name"] == "build"
    end

    test "per-task attestation falls back to direct output hashing when cache is unavailable", %{
      workdir: workdir
    } do
      occ = build_occurrence_with_data()
      graph = parse_graph!([%{"name" => "build", "command" => "make", "outputs" => ["out/app"]}])

      out_dir = Path.join(workdir, "out")
      File.mkdir_p!(out_dir)
      File.write!(Path.join(out_dir, "app"), "binary content")

      assert [{"build", att}] = Attestation.generate_per_task(occ, graph, workdir)
      assert [%{"name" => "out/app"}] = att["subject"]
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # DSSE Envelope
  # ─────────────────────────────────────────────────────────────────────────────

  describe "Envelope" do
    test "wrap produces valid DSSE structure" do
      attestation = %{"_type" => "test", "data" => "hello"}
      assert {:ok, env} = Envelope.wrap(attestation)
      assert env["payloadType"] == "application/vnd.in-toto+json"
      assert is_binary(env["payload"])
      assert env["signatures"] == []
    end

    test "decode_payload round-trips through wrap" do
      attestation = %{"_type" => "test", "key" => "value"}
      {:ok, env} = Envelope.wrap(attestation)
      assert {:ok, decoded} = Envelope.decode_payload(env)
      assert decoded == attestation
    end

    test "sign adds a signature" do
      {:ok, env} = Envelope.wrap(%{"data" => "test"})
      assert {:ok, signed} = Envelope.sign(env, HMAC, key: "test-secret")
      assert length(signed["signatures"]) == 1
      sig = hd(signed["signatures"])
      assert sig["keyid"] == "hmac-sha256"
      assert is_binary(sig["sig"])
    end

    test "verify validates correct signature" do
      {:ok, env} = Envelope.wrap(%{"data" => "test"})
      {:ok, signed} = Envelope.sign(env, HMAC, key: "test-secret")
      assert :ok = Envelope.verify(signed, HMAC, key: "test-secret")
    end

    test "verify rejects wrong key" do
      {:ok, env} = Envelope.wrap(%{"data" => "test"})
      {:ok, signed} = Envelope.sign(env, HMAC, key: "correct-key")
      assert {:error, :no_valid_signature} = Envelope.verify(signed, HMAC, key: "wrong-key")
    end

    test "verify rejects unsigned envelope" do
      {:ok, env} = Envelope.wrap(%{"data" => "test"})
      assert {:error, :no_valid_signature} = Envelope.verify(env, HMAC, key: "any-key")
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # HMAC Signer
  # ─────────────────────────────────────────────────────────────────────────────

  describe "HMAC signer" do
    test "sign returns error without key" do
      assert {:error, :no_signing_key} = HMAC.sign("payload", [])
    end

    test "sign produces deterministic signatures" do
      {:ok, sig1, _} = HMAC.sign("payload", key: "secret")
      {:ok, sig2, _} = HMAC.sign("payload", key: "secret")
      assert sig1 == sig2
    end

    test "different payloads produce different signatures" do
      {:ok, sig1, _} = HMAC.sign("payload1", key: "secret")
      {:ok, sig2, _} = HMAC.sign("payload2", key: "secret")
      assert sig1 != sig2
    end

    test "verify returns true for valid signature" do
      {:ok, sig, keyid} = HMAC.sign("payload", key: "secret")
      assert HMAC.verify("payload", sig, keyid, key: "secret")
    end

    test "verify returns false for tampered payload" do
      {:ok, sig, keyid} = HMAC.sign("payload", key: "secret")
      refute HMAC.verify("tampered", sig, keyid, key: "secret")
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # GitContext.normalize_remote_url/1
  # ─────────────────────────────────────────────────────────────────────────────

  describe "GitContext.normalize_remote_url/1" do
    test "converts SSH URL to HTTPS" do
      assert GitContext.normalize_remote_url("git@github.com:org/repo.git") ==
               "https://github.com/org/repo"
    end

    test "strips trailing .git from HTTPS URL" do
      assert GitContext.normalize_remote_url("https://github.com/org/repo.git") ==
               "https://github.com/org/repo"
    end

    test "converts ssh:// URL to HTTPS" do
      assert GitContext.normalize_remote_url("ssh://git@github.com/org/repo.git") ==
               "https://github.com/org/repo"
    end

    test "strips port from ssh:// URL" do
      assert GitContext.normalize_remote_url("ssh://git@gitlab.example.com:22/org/repo.git") ==
               "https://gitlab.example.com/org/repo"
    end

    test "handles already-clean HTTPS URL" do
      assert GitContext.normalize_remote_url("https://github.com/org/repo") ==
               "https://github.com/org/repo"
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # FIXTURES
  # ─────────────────────────────────────────────────────────────────────────────

  defp build_occurrence(data) do
    %Occurrence{
      id: Sykli.ULID.generate(),
      timestamp: DateTime.utc_now(),
      protocol_version: "1.0",
      type: "ci.run.passed",
      source: "sykli",
      severity: :info,
      outcome: "success",
      run_id: "test-run-#{:erlang.unique_integer([:positive])}",
      node: :nonode@nohost,
      context: %{},
      data: data,
      error: nil,
      reasoning: nil,
      history: nil
    }
  end

  defp build_occurrence_with_data do
    build_occurrence(%{
      "git" => %{
        "sha" => "abc123def456789",
        "branch" => "main",
        "remote_url" => "https://github.com/org/repo",
        "recent_commits" => [],
        "changed_files" => []
      },
      "summary" => %{
        "passed" => 1,
        "failed" => 0,
        "errored" => 0,
        "cached" => 0,
        "skipped" => 0
      }
    })
  end

  defp build_failed_occurrence do
    %{build_occurrence_with_data() | type: "ci.run.failed", outcome: "failure", severity: :error}
  end

  defp parse_graph!(tasks) do
    json = Jason.encode!(%{"tasks" => tasks})
    {:ok, graph} = Sykli.Graph.parse(json)
    graph
  end

  defp setup_cache_entry(graph, task_name, workdir) do
    task = Map.fetch!(graph, task_name)
    Sykli.Cache.init()

    out_dir = Path.join(workdir, "out")
    File.mkdir_p!(out_dir)
    File.write!(Path.join(out_dir, "app"), "binary content")

    Sykli.Cache.store(
      Sykli.Cache.cache_key(task, workdir),
      task,
      ["out/app"],
      100,
      workdir
    )
  end
end
