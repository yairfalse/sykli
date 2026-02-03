defmodule SykliTest do
  use ExUnit.Case

  describe "DSL" do
    test "simple pipeline" do
      use Sykli

      result = pipeline do
        task "test" do
          run "mix test"
        end
      end

      assert length(result.tasks) == 1
      assert hd(result.tasks).name == "test"
      assert hd(result.tasks).command == "mix test"
    end

    test "multiple tasks with dependencies" do
      use Sykli

      result = pipeline do
        task "test" do
          run "mix test"
        end

        task "build" do
          run "mix compile"
          after_ ["test"]
        end
      end

      assert length(result.tasks) == 2

      build_task = Enum.find(result.tasks, &(&1.name == "build"))
      assert build_task.depends_on == ["test"]
    end

    test "task with all options" do
      use Sykli

      result = pipeline do
        task "full" do
          run "mix test"
          container "elixir:1.16"
          workdir "/app"
          inputs ["**/*.ex"]
          outputs ["_build"]
          env "MIX_ENV", "test"
          when_ "branch == 'main'"
          secret "HEX_API_KEY"
          retry 3
          timeout 300
        end
      end

      task = hd(result.tasks)
      assert task.container == "elixir:1.16"
      assert task.workdir == "/app"
      assert task.inputs == ["**/*.ex"]
      assert task.env == %{"MIX_ENV" => "test"}
      assert task.condition == "branch == 'main'"
      assert task.secrets == ["HEX_API_KEY"]
      assert task.retry == 3
      assert task.timeout == 300
    end

    test "dynamic tasks with for loop" do
      use Sykli

      result = pipeline do
        services = ["api", "web"]

        for svc <- services do
          task "test-#{svc}" do
            run "mix test apps/#{svc}"
          end
        end
      end

      assert length(result.tasks) == 2
      names = Enum.map(result.tasks, & &1.name) |> Enum.sort()
      assert names == ["test-api", "test-web"]
    end

    test "resources" do
      use Sykli

      result = pipeline do
        src = dir(".", as: "src")
        deps_cache = cache("mix-deps")

        task "test" do
          container "elixir:1.16"
          mount src, "/app"
          mount_cache deps_cache, "/root/.mix"
          workdir "/app"
          run "mix test"
        end
      end

      assert map_size(result.resources) == 2
      assert result.resources["src"].type == :directory
      assert result.resources["mix-deps"].type == :cache

      task = hd(result.tasks)
      assert length(task.mounts) == 2
    end
  end

  describe "validation" do
    test "raises on missing command" do
      use Sykli

      assert_raise RuntimeError, ~r/has no command/, fn ->
        pipeline do
          task "empty" do
            # no run!
          end
        end
        |> Sykli.Emitter.validate!()
      end
    end

    test "raises on unknown dependency" do
      use Sykli

      assert_raise RuntimeError, ~r/unknown task/, fn ->
        pipeline do
          task "build" do
            run "mix compile"
            after_ ["nonexistent"]
          end
        end
        |> Sykli.Emitter.validate!()
      end
    end

    test "raises on cycle" do
      use Sykli

      assert_raise RuntimeError, ~r/cycle detected/, fn ->
        pipeline do
          task "a" do
            run "echo a"
            after_ ["b"]
          end

          task "b" do
            run "echo b"
            after_ ["a"]
          end
        end
        |> Sykli.Emitter.validate!()
      end
    end

    test "suggests similar task name on typo" do
      use Sykli

      assert_raise RuntimeError, ~r/did you mean "build"/, fn ->
        pipeline do
          task "build" do
            run "mix compile"
          end

          task "deploy" do
            run "mix deploy"
            after_ ["buld"]  # typo
          end
        end
        |> Sykli.Emitter.validate!()
      end
    end
  end

  describe "K8s validation (Minimal API)" do
    alias Sykli.K8s

    test "accepts valid memory formats" do
      assert {:ok, _} = K8s.validate(K8s.options() |> K8s.memory("512Mi"))
      assert {:ok, _} = K8s.validate(K8s.options() |> K8s.memory("4Gi"))
      assert {:ok, _} = K8s.validate(K8s.options() |> K8s.memory("1Ti"))
    end

    test "rejects invalid memory with suggestion" do
      {:error, [error]} = K8s.validate(K8s.options() |> K8s.memory("4gb"))
      assert error.message =~ "did you mean 'Gi'?"

      {:error, [error]} = K8s.validate(K8s.options() |> K8s.memory("512mb"))
      assert error.message =~ "did you mean 'Mi'?"

      {:error, [error]} = K8s.validate(K8s.options() |> K8s.memory("1kb"))
      assert error.message =~ "did you mean 'Ki'?"
    end

    test "accepts valid CPU formats" do
      assert {:ok, _} = K8s.validate(K8s.options() |> K8s.cpu("500m"))
      assert {:ok, _} = K8s.validate(K8s.options() |> K8s.cpu("0.5"))
      assert {:ok, _} = K8s.validate(K8s.options() |> K8s.cpu("2"))
    end

    test "rejects invalid CPU formats" do
      {:error, [error]} = K8s.validate(K8s.options() |> K8s.cpu("2cores"))
      assert error.message =~ "invalid CPU format"
    end

    test "sets gpu" do
      opts = K8s.options() |> K8s.gpu(2)
      assert opts.gpu == 2
    end

    test "raw passes through advanced options" do
      opts = K8s.options()
             |> K8s.memory("32Gi")
             |> K8s.gpu(1)
             |> K8s.raw(~s({"nodeSelector": {"gpu": "true"}}))

      assert opts.memory == "32Gi"
      assert opts.gpu == 1
      assert opts.raw =~ "nodeSelector"
    end

    test "k8s options in task emits correctly" do
      use Sykli

      result = pipeline do
        task "build" do
          run "cargo build"
          k8s K8s.options()
               |> K8s.memory("4Gi")
               |> K8s.cpu("2")
               |> K8s.gpu(1)
        end
      end

      json = Sykli.Emitter.to_json(result)
      decoded = Jason.decode!(json)

      task = hd(decoded["tasks"])
      assert task["k8s"]["memory"] == "4Gi"
      assert task["k8s"]["cpu"] == "2"
      assert task["k8s"]["gpu"] == 1
    end

    test "k8s raw escape hatch emits correctly" do
      use Sykli

      result = pipeline do
        task "gpu-train" do
          run "python train.py"
          k8s K8s.options()
               |> K8s.memory("32Gi")
               |> K8s.gpu(1)
               |> K8s.raw(~s({"serviceAccount": "ml-runner"}))
        end
      end

      json = Sykli.Emitter.to_json(result)
      decoded = Jason.decode!(json)

      task = hd(decoded["tasks"])
      assert task["k8s"]["memory"] == "32Gi"
      assert task["k8s"]["gpu"] == 1
      assert task["k8s"]["raw"] =~ "serviceAccount"
    end

    test "raises on invalid k8s in pipeline validation" do
      use Sykli

      assert_raise Sykli.K8s.ValidationError, ~r/did you mean 'Gi'/, fn ->
        pipeline do
          task "build" do
            run "cargo build"
            k8s K8s.options() |> K8s.memory("4gb")
          end
        end
        |> Sykli.Emitter.validate!()
      end
    end
  end

  describe "Vault path validation" do
    test "rejects invalid vault path" do
      use Sykli

      assert_raise ArgumentError, ~r/SecretRef.from_vault\(\) requires 'path#field' format/, fn ->
        pipeline do
          task "deploy" do
            run "./deploy.sh"
            secret_from "DB_PASS", Sykli.SecretRef.from_vault("secret/data/db")  # missing #field
          end
        end
        |> Sykli.Emitter.validate!()
      end
    end

    test "accepts valid vault path" do
      use Sykli

      result = pipeline do
        task "deploy" do
          run "./deploy.sh"
          secret_from "DB_PASS", Sykli.SecretRef.from_vault("secret/data/db#password")
        end
      end

      # Should not raise
      Sykli.Emitter.validate!(result)
    end
  end

  describe "presets" do
    test "mix_test creates test task" do
      use Sykli

      result = pipeline do
        mix_test()
      end

      task = hd(result.tasks)
      assert task.name == "test"
      assert task.command == "mix test"
      assert "**/*.ex" in task.inputs
    end

    test "mix_credo creates credo task" do
      use Sykli

      result = pipeline do
        mix_credo()
      end

      task = hd(result.tasks)
      assert task.name == "credo"
      assert task.command == "mix credo --strict"
    end

    test "presets with custom names" do
      use Sykli

      result = pipeline do
        mix_test(name: "unit-test")
      end

      assert hd(result.tasks).name == "unit-test"
    end
  end

  describe "requires (node placement)" do
    test "single required label" do
      use Sykli

      result = pipeline do
        task "train" do
          run "python train.py"
          requires ["gpu"]
        end
      end

      task = hd(result.tasks)
      assert task.requires == ["gpu"]
    end

    test "multiple required labels" do
      use Sykli

      result = pipeline do
        task "build" do
          run "docker build"
          requires ["docker", "arm64"]
        end
      end

      task = hd(result.tasks)
      assert task.requires == ["docker", "arm64"]
    end

    test "requires emits to JSON" do
      use Sykli

      result = pipeline do
        task "train" do
          run "python train.py"
          requires ["gpu", "high-memory"]
        end
      end

      json = Sykli.Emitter.to_json(result)
      decoded = Jason.decode!(json)

      task = hd(decoded["tasks"])
      assert task["requires"] == ["gpu", "high-memory"]
    end

    test "omits requires when empty" do
      use Sykli

      result = pipeline do
        task "test" do
          run "mix test"
        end
      end

      json = Sykli.Emitter.to_json(result)
      decoded = Jason.decode!(json)

      task = hd(decoded["tasks"])
      refute Map.has_key?(task, "requires")
    end
  end

  describe "AI-native features" do
    test "semantic metadata (covers, intent, criticality)" do
      use Sykli

      result = pipeline do
        task "auth-test" do
          run "mix test test/auth"
          covers ["lib/auth/**/*.ex", "lib/auth.ex"]
          intent "Tests authentication and authorization"
          critical()
        end
      end

      task = hd(result.tasks)
      assert task.semantic.covers == ["lib/auth/**/*.ex", "lib/auth.ex"]
      assert task.semantic.intent == "Tests authentication and authorization"
      assert task.semantic.criticality == :high
    end

    test "ai_hooks (on_fail, select)" do
      use Sykli

      result = pipeline do
        task "flaky-test" do
          run "mix test --only integration"
          on_fail(:retry)
          select_mode(:smart)
        end
      end

      task = hd(result.tasks)
      assert task.ai_hooks.on_fail == :retry
      assert task.ai_hooks.select == :smart
    end

    test "smart() shorthand" do
      use Sykli

      result = pipeline do
        task "unit-test" do
          run "mix test"
          covers ["lib/**/*.ex"]
          smart()
        end
      end

      task = hd(result.tasks)
      assert task.ai_hooks.select == :smart
    end

    test "set_criticality with levels" do
      use Sykli

      result = pipeline do
        task "lint" do
          run "mix credo"
          set_criticality(:low)
        end
      end

      task = hd(result.tasks)
      assert task.semantic.criticality == :low
    end

    test "AI-native fields emit to JSON" do
      use Sykli

      result = pipeline do
        task "auth-test" do
          run "mix test test/auth"
          covers ["lib/auth/**/*.ex"]
          intent "Auth tests"
          critical()
          on_fail(:analyze)
          smart()
        end
      end

      json = Sykli.Emitter.to_json(result)
      decoded = Jason.decode!(json)

      task = hd(decoded["tasks"])
      assert task["semantic"]["covers"] == ["lib/auth/**/*.ex"]
      assert task["semantic"]["intent"] == "Auth tests"
      assert task["semantic"]["criticality"] == "high"
      assert task["ai_hooks"]["on_fail"] == "analyze"
      assert task["ai_hooks"]["select"] == "smart"
    end

    test "omits AI-native fields when not set" do
      use Sykli

      result = pipeline do
        task "test" do
          run "mix test"
        end
      end

      json = Sykli.Emitter.to_json(result)
      decoded = Jason.decode!(json)

      task = hd(decoded["tasks"])
      refute Map.has_key?(task, "semantic")
      refute Map.has_key?(task, "ai_hooks")
    end

    test "fluent helpers for task_ref" do
      use Sykli

      result = pipeline do
        parallel("tests", [
          task_ref("auth-test")
          |> run_cmd("mix test test/auth")
          |> with_covers(["lib/auth/**/*.ex"])
          |> with_intent("Auth tests")
          |> with_critical()
          |> with_smart()
        ])
      end

      task = Enum.find(result.tasks, &(&1.name == "auth-test"))
      assert task.semantic.covers == ["lib/auth/**/*.ex"]
      assert task.semantic.intent == "Auth tests"
      assert task.semantic.criticality == :high
      assert task.ai_hooks.select == :smart
    end
  end

  describe "JSON emission" do
    test "emits v1 for simple pipeline" do
      use Sykli

      result = pipeline do
        task "test" do
          run "mix test"
        end
      end

      json = Sykli.Emitter.to_json(result)
      decoded = Jason.decode!(json)

      assert decoded["version"] == "1"
      assert length(decoded["tasks"]) == 1
      assert hd(decoded["tasks"])["name"] == "test"
    end

    test "emits v2 when containers used" do
      use Sykli

      result = pipeline do
        task "test" do
          container "elixir:1.16"
          run "mix test"
        end
      end

      json = Sykli.Emitter.to_json(result)
      decoded = Jason.decode!(json)

      assert decoded["version"] == "2"
    end

    test "elixir_inputs returns expected patterns" do
      use Sykli

      inputs = elixir_inputs()

      assert "**/*.ex" in inputs
      assert "**/*.exs" in inputs
      assert "mix.exs" in inputs
      assert "mix.lock" in inputs
    end
  end
end
