defmodule Sykli.K8s.Resources.JobTest do
  use ExUnit.Case, async: true

  alias Sykli.K8s.Resources.Job
  alias Sykli.K8s.Error

  # Mock config used across tests
  @config %{
    api_url: "https://kubernetes.default.svc",
    auth: {:bearer, "test-token"},
    ca_cert: nil,
    namespace: "default"
  }

  describe "create/3" do
    test "creates job from manifest" do
      manifest = %{
        "apiVersion" => "batch/v1",
        "kind" => "Job",
        "metadata" => %{
          "name" => "test-job",
          "namespace" => "default"
        },
        "spec" => %{
          "template" => %{
            "spec" => %{
              "containers" => [
                %{"name" => "main", "image" => "alpine", "command" => ["echo", "hello"]}
              ],
              "restartPolicy" => "Never"
            }
          }
        }
      }

      result =
        Job.create(manifest, @config,
          client: fn :post, path, body, _config, _opts ->
            assert path == "/apis/batch/v1/namespaces/default/jobs"
            assert body["kind"] == "Job"
            assert body["metadata"]["name"] == "test-job"

            {:ok, Map.put(body, "status", %{})}
          end
        )

      assert {:ok, job} = result
      assert job["metadata"]["name"] == "test-job"
    end

    test "returns conflict error when job already exists" do
      manifest = %{
        "apiVersion" => "batch/v1",
        "kind" => "Job",
        "metadata" => %{"name" => "existing-job", "namespace" => "default"},
        "spec" => %{}
      }

      result =
        Job.create(manifest, @config,
          client: fn :post, _path, _body, _config, _opts ->
            {:error, %Error{type: :conflict, status_code: 409, message: "already exists"}}
          end
        )

      assert {:error, %Error{type: :conflict}} = result
    end

    test "infers namespace from manifest metadata" do
      manifest = %{
        "apiVersion" => "batch/v1",
        "kind" => "Job",
        "metadata" => %{"name" => "job", "namespace" => "custom-ns"},
        "spec" => %{}
      }

      result =
        Job.create(manifest, @config,
          client: fn :post, path, _body, _config, _opts ->
            assert path == "/apis/batch/v1/namespaces/custom-ns/jobs"
            {:ok, manifest}
          end
        )

      assert {:ok, _} = result
    end
  end

  describe "get/3" do
    test "gets job by name and namespace" do
      result =
        Job.get("my-job", "default", @config,
          client: fn :get, path, nil, _config, _opts ->
            assert path == "/apis/batch/v1/namespaces/default/jobs/my-job"
            {:ok, %{"metadata" => %{"name" => "my-job"}, "status" => %{"succeeded" => 1}}}
          end
        )

      assert {:ok, job} = result
      assert job["status"]["succeeded"] == 1
    end

    test "returns not_found error when job doesn't exist" do
      result =
        Job.get("nonexistent", "default", @config,
          client: fn :get, _path, nil, _config, _opts ->
            {:error, %Error{type: :not_found, status_code: 404}}
          end
        )

      assert {:error, %Error{type: :not_found}} = result
    end
  end

  describe "delete/4" do
    test "deletes job with propagation policy" do
      result =
        Job.delete("my-job", "default", @config,
          client: fn :delete, path, body, _config, _opts ->
            assert path == "/apis/batch/v1/namespaces/default/jobs/my-job"
            assert body["propagationPolicy"] == "Background"
            {:ok, %{"status" => "Success"}}
          end
        )

      assert {:ok, _} = result
    end

    test "accepts foreground propagation policy" do
      result =
        Job.delete("my-job", "default", @config,
          propagation: :foreground,
          client: fn :delete, _path, body, _config, _opts ->
            assert body["propagationPolicy"] == "Foreground"
            {:ok, %{"status" => "Success"}}
          end
        )

      assert {:ok, _} = result
    end

    test "returns not_found error when job doesn't exist" do
      result =
        Job.delete("nonexistent", "default", @config,
          client: fn :delete, _path, _body, _config, _opts ->
            {:error, %Error{type: :not_found, status_code: 404}}
          end
        )

      assert {:error, %Error{type: :not_found}} = result
    end
  end

  describe "wait_complete/4" do
    test "returns :succeeded when job completes successfully" do
      call_count = :counters.new(1, [:atomics])

      result =
        Job.wait_complete("my-job", "default", @config,
          timeout: 5000,
          poll_interval: 10,
          client: fn :get, _path, nil, _config, _opts ->
            :counters.add(call_count, 1, 1)
            count = :counters.get(call_count, 1)

            if count < 3 do
              {:ok, %{"status" => %{"active" => 1}}}
            else
              {:ok,
               %{
                 "status" => %{
                   "succeeded" => 1,
                   "conditions" => [
                     %{"type" => "Complete", "status" => "True"}
                   ]
                 }
               }}
            end
          end
        )

      assert {:ok, :succeeded} = result
      assert :counters.get(call_count, 1) >= 3
    end

    test "returns :failed when job fails" do
      result =
        Job.wait_complete("failing-job", "default", @config,
          timeout: 5000,
          poll_interval: 10,
          client: fn :get, _path, nil, _config, _opts ->
            {:ok,
             %{
               "status" => %{
                 "failed" => 1,
                 "conditions" => [
                   %{"type" => "Failed", "status" => "True", "reason" => "BackoffLimitExceeded"}
                 ]
               }
             }}
          end
        )

      assert {:ok, :failed} = result
    end

    test "returns timeout error when job doesn't complete in time" do
      result =
        Job.wait_complete("slow-job", "default", @config,
          timeout: 50,
          poll_interval: 20,
          client: fn :get, _path, nil, _config, _opts ->
            {:ok, %{"status" => %{"active" => 1}}}
          end
        )

      assert {:error, %Error{type: :timeout}} = result
    end

    test "returns error if job disappears during wait" do
      call_count = :counters.new(1, [:atomics])

      result =
        Job.wait_complete("disappearing-job", "default", @config,
          timeout: 5000,
          poll_interval: 10,
          client: fn :get, _path, nil, _config, _opts ->
            :counters.add(call_count, 1, 1)
            count = :counters.get(call_count, 1)

            if count < 2 do
              {:ok, %{"status" => %{"active" => 1}}}
            else
              {:error, %Error{type: :not_found, status_code: 404}}
            end
          end
        )

      assert {:error, %Error{type: :not_found}} = result
    end
  end

  describe "logs/4" do
    test "gets logs from job's pod" do
      result =
        Job.logs("my-job", "default", @config,
          pod_client: fn :get, path, nil, _config, _opts ->
            if String.contains?(path, "/pods") and not String.contains?(path, "/log") do
              {:ok,
               %{
                 "items" => [
                   %{"metadata" => %{"name" => "my-job-abc123"}}
                 ]
               }}
            else
              assert String.contains?(path, "my-job-abc123/log")
              {:ok, "Hello from container!\n"}
            end
          end
        )

      assert {:ok, "Hello from container!\n"} = result
    end

    test "returns error when no pods found for job" do
      result =
        Job.logs("orphan-job", "default", @config,
          pod_client: fn :get, _path, nil, _config, _opts ->
            {:ok, %{"items" => []}}
          end
        )

      assert {:error, :no_pods} = result
    end

    test "accepts container name option" do
      result =
        Job.logs("multi-container-job", "default", @config,
          container: "sidecar",
          pod_client: fn :get, path, nil, _config, _opts ->
            if String.contains?(path, "/pods") and not String.contains?(path, "/log") do
              {:ok,
               %{
                 "items" => [
                   %{"metadata" => %{"name" => "multi-container-job-xyz"}}
                 ]
               }}
            else
              assert String.contains?(path, "container=sidecar")
              {:ok, "Sidecar logs\n"}
            end
          end
        )

      assert {:ok, "Sidecar logs\n"} = result
    end

    test "handles pod not ready yet" do
      call_count = :counters.new(1, [:atomics])

      result =
        Job.logs("starting-job", "default", @config,
          retry_delay: 10,
          max_retries: 3,
          pod_client: fn :get, path, nil, _config, _opts ->
            :counters.add(call_count, 1, 1)
            count = :counters.get(call_count, 1)

            if String.contains?(path, "/pods") and not String.contains?(path, "/log") do
              if count < 2 do
                {:ok, %{"items" => []}}
              else
                {:ok, %{"items" => [%{"metadata" => %{"name" => "starting-job-pod"}}]}}
              end
            else
              {:ok, "Finally ready!\n"}
            end
          end
        )

      assert {:ok, "Finally ready!\n"} = result
    end
  end

  describe "status/1" do
    test "parses succeeded status" do
      job = %{"status" => %{"succeeded" => 1}}
      assert Job.status(job) == :succeeded
    end

    test "parses failed status" do
      job = %{"status" => %{"failed" => 1}}
      assert Job.status(job) == :failed
    end

    test "parses active status" do
      job = %{"status" => %{"active" => 1}}
      assert Job.status(job) == :active
    end

    test "parses pending status when no status field" do
      job = %{"status" => %{}}
      assert Job.status(job) == :pending
    end

    test "parses pending when status is nil" do
      job = %{}
      assert Job.status(job) == :pending
    end
  end

  describe "build_manifest/2" do
    test "builds minimal job manifest" do
      manifest =
        Job.build_manifest("test-job",
          image: "alpine:latest",
          command: ["echo", "hello"],
          namespace: "default"
        )

      assert manifest["apiVersion"] == "batch/v1"
      assert manifest["kind"] == "Job"
      assert manifest["metadata"]["name"] == "test-job"
      assert manifest["metadata"]["namespace"] == "default"

      container = hd(manifest["spec"]["template"]["spec"]["containers"])
      assert container["image"] == "alpine:latest"
      assert container["command"] == ["echo", "hello"]
    end

    test "adds labels to job" do
      manifest =
        Job.build_manifest("labeled-job",
          image: "alpine",
          command: ["true"],
          namespace: "default",
          labels: %{"app" => "sykli", "task" => "test"}
        )

      assert manifest["metadata"]["labels"]["app"] == "sykli"
      assert manifest["metadata"]["labels"]["task"] == "test"
    end

    test "adds environment variables" do
      manifest =
        Job.build_manifest("env-job",
          image: "alpine",
          command: ["printenv"],
          namespace: "default",
          env: %{"FOO" => "bar", "BAZ" => "qux"}
        )

      container = hd(manifest["spec"]["template"]["spec"]["containers"])
      env_vars = container["env"]

      assert Enum.any?(env_vars, fn e -> e["name"] == "FOO" and e["value"] == "bar" end)
      assert Enum.any?(env_vars, fn e -> e["name"] == "BAZ" and e["value"] == "qux" end)
    end

    test "adds volume mounts" do
      manifest =
        Job.build_manifest("mounted-job",
          image: "alpine",
          command: ["ls", "/data"],
          namespace: "default",
          volumes: [
            %{name: "data", host_path: "/tmp/data", mount_path: "/data"}
          ]
        )

      container = hd(manifest["spec"]["template"]["spec"]["containers"])
      volumes = manifest["spec"]["template"]["spec"]["volumes"]

      assert Enum.any?(volumes, fn v -> v["name"] == "data" end)
      assert Enum.any?(container["volumeMounts"], fn m -> m["mountPath"] == "/data" end)
    end

    test "sets backoff limit" do
      manifest =
        Job.build_manifest("retry-job",
          image: "alpine",
          command: ["false"],
          namespace: "default",
          backoff_limit: 3
        )

      assert manifest["spec"]["backoffLimit"] == 3
    end

    test "sets TTL after finished" do
      manifest =
        Job.build_manifest("cleanup-job",
          image: "alpine",
          command: ["true"],
          namespace: "default",
          ttl_seconds: 60
        )

      assert manifest["spec"]["ttlSecondsAfterFinished"] == 60
    end
  end
end
