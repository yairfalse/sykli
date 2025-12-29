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

  describe "BuildAndPush task definitions" do
    test "defines build task" do
      tasks = BuildAndPush.__module__(:tasks)
      build = Enum.find(tasks, &(&1.name == "build"))

      assert build != nil
      assert build.container == "docker:24-dind"
      assert build.command =~ "docker build"
      assert build.command =~ "${image}"
      assert build.privileged == true
    end

    test "defines push task with conditional" do
      tasks = BuildAndPush.__module__(:tasks)
      push = Enum.find(tasks, &(&1.name == "push"))

      assert push != nil
      assert push.command == "docker push ${image}"
      assert push.when == {:param, :push}
      assert "build" in push.depends_on
    end

    test "defines scan task with conditional" do
      tasks = BuildAndPush.__module__(:tasks)
      scan = Enum.find(tasks, &(&1.name == "scan"))

      assert scan != nil
      assert scan.command =~ "docker scout"
      assert scan.when == {:param, :scan}
      assert "build" in scan.depends_on
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

    test "exports tasks with conditions" do
      json = BuildAndPush.to_json()
      tasks = json["tasks"]

      build = Enum.find(tasks, &(&1["name"] == "build"))
      assert build["container"] == "docker:24-dind"
      assert build["command"] =~ "docker build"

      push = Enum.find(tasks, &(&1["name"] == "push"))
      assert push["when"] == %{"type" => "param", "field" => "push"}
      assert "build" in push["depends_on"]
    end
  end
end
