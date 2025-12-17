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
  end
end
