defmodule Sykli.Modules.DockerTest do
  use ExUnit.Case, async: true

  alias Sykli.Modules.Docker.BuildAndPush

  describe "BuildAndPush module metadata" do
    test "has correct version" do
      assert BuildAndPush.__module__(:version) == "1.0.0"
    end

    test "has correct group" do
      assert BuildAndPush.__module__(:group) == "docker"
    end

    test "requires docker capability" do
      assert BuildAndPush.__module__(:requires) == [:docker]
    end

    test "has all expected params" do
      params = BuildAndPush.__module__(:params)
      param_names = Enum.map(params, fn {name, _, _} -> name end)

      assert :image in param_names
      assert :dockerfile in param_names
      assert :context in param_names
      assert :build_args in param_names
      assert :push in param_names
      assert :scan in param_names
    end
  end

  describe "BuildAndPush validation" do
    test "requires image" do
      config = %BuildAndPush{image: nil}
      assert {:error, [{:image, "is required"}]} = BuildAndPush.validate(config)
    end

    test "validates with image provided" do
      config = %BuildAndPush{image: "myapp:latest"}
      assert :ok = BuildAndPush.validate(config)
    end
  end

  describe "BuildAndPush.tasks/1" do
    test "generates build task" do
      config = %BuildAndPush{image: "myapp:latest", push: false}
      tasks = BuildAndPush.tasks(config)

      build = Enum.find(tasks, &(&1.name == "build"))
      assert build != nil
      assert build.module == "docker"
      assert build.container == "docker:24-dind"
      assert build.command =~ "docker build"
      assert build.command =~ "-t myapp:latest"
    end

    test "generates push task when push: true" do
      config = %BuildAndPush{image: "myapp:latest", push: true}
      tasks = BuildAndPush.tasks(config)

      push = Enum.find(tasks, &(&1.name == "push"))
      assert push != nil
      assert push.command == "docker push myapp:latest"
      assert "build" in push.depends_on
    end

    test "does not generate push task when push: false" do
      config = %BuildAndPush{image: "myapp:latest", push: false}
      tasks = BuildAndPush.tasks(config)

      push = Enum.find(tasks, &(&1.name == "push"))
      assert push == nil
    end

    test "generates scan task when scan: true" do
      config = %BuildAndPush{image: "myapp:latest", scan: true, push: false}
      tasks = BuildAndPush.tasks(config)

      scan = Enum.find(tasks, &(&1.name == "scan"))
      assert scan != nil
      assert scan.command =~ "docker scout"
      assert "build" in scan.depends_on
    end

    test "push depends on scan when both enabled" do
      config = %BuildAndPush{image: "myapp:latest", scan: true, push: true}
      tasks = BuildAndPush.tasks(config)

      push = Enum.find(tasks, &(&1.name == "push"))
      assert "build" in push.depends_on
      assert "scan" in push.depends_on
    end

    test "respects custom dockerfile" do
      config = %BuildAndPush{image: "myapp:latest", dockerfile: "Dockerfile.prod", push: false}
      tasks = BuildAndPush.tasks(config)

      build = Enum.find(tasks, &(&1.name == "build"))
      assert build.command =~ "-f Dockerfile.prod"
    end

    test "respects custom context" do
      config = %BuildAndPush{image: "myapp:latest", context: "./app", push: false}
      tasks = BuildAndPush.tasks(config)

      build = Enum.find(tasks, &(&1.name == "build"))
      assert build.command =~ "./app"
    end

    test "includes build args" do
      config = %BuildAndPush{
        image: "myapp:latest",
        build_args: %{"VERSION" => "1.0.0", "ENV" => "prod"},
        push: false
      }

      tasks = BuildAndPush.tasks(config)

      build = Enum.find(tasks, &(&1.name == "build"))
      assert build.command =~ "--build-arg VERSION=1.0.0"
      assert build.command =~ "--build-arg ENV=prod"
    end

    test "includes platform when specified" do
      config = %BuildAndPush{
        image: "myapp:latest",
        platform: "linux/amd64",
        push: false
      }

      tasks = BuildAndPush.tasks(config)

      build = Enum.find(tasks, &(&1.name == "build"))
      assert build.command =~ "--platform linux/amd64"
    end
  end

  describe "JSON export" do
    test "exports module definition" do
      json = BuildAndPush.to_json()

      assert json["group"] == "docker"
      assert json["version"] == "1.0.0"
      assert json["requires"] == ["docker"]

      image_param = Enum.find(json["params"], &(&1["name"] == "image"))
      assert image_param["type"] == "string"
      assert image_param["required"] == true
    end
  end
end
