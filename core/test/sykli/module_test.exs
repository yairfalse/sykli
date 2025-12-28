defmodule Sykli.ModuleTest do
  use ExUnit.Case, async: true

  describe "Module DSL" do
    defmodule TestModule do
      use Sykli.Module

      @version "1.0.0"

      param(:image, :string, required: true, doc: "Docker image name")
      param(:dockerfile, :string, default: "Dockerfile", doc: "Path to Dockerfile")
      param(:context, :string, default: ".")
      param(:push, :boolean, default: true)
      param(:build_args, {:map, :string, :string}, default: %{})

      requires([:docker])
    end

    test "generates struct with param fields" do
      config = %TestModule{image: "myapp:latest"}
      assert config.image == "myapp:latest"
      # default applied later
      assert config.dockerfile == nil
      # default applied later
      assert config.push == nil
    end

    test "reports module version" do
      assert TestModule.__module__(:version) == "1.0.0"
    end

    test "reports module group" do
      # From "Sykli.ModuleTest.TestModule" -> "moduletest"
      assert TestModule.__module__(:group) == "moduletest"
    end

    test "reports required capabilities" do
      assert TestModule.__module__(:requires) == [:docker]
    end

    test "reports param specifications" do
      params = TestModule.__module__(:params)
      assert length(params) == 5

      # Check first param
      {name, type, opts} = Enum.find(params, fn {n, _, _} -> n == :image end)
      assert name == :image
      assert type == :string
      assert Keyword.get(opts, :required) == true
      assert Keyword.get(opts, :doc) == "Docker image name"
    end

    test "param metadata functions" do
      assert TestModule.__param__(:image, :type) == :string
      assert TestModule.__param__(:image, :required) == true
      assert TestModule.__param__(:image, :doc) == "Docker image name"

      assert TestModule.__param__(:dockerfile, :type) == :string
      assert TestModule.__param__(:dockerfile, :required) == false
      assert TestModule.__param__(:dockerfile, :default) == "Dockerfile"
    end
  end

  describe "validation" do
    defmodule ValidatedModule do
      use Sykli.Module

      param(:name, :string, required: true)
      param(:count, :integer, default: 1)

      requires([])
    end

    test "validates required fields" do
      config = %ValidatedModule{name: nil}
      assert {:error, [{:name, "is required"}]} = ValidatedModule.validate(config)
    end

    test "validates passes with required field present" do
      config = %ValidatedModule{name: "test"}
      assert :ok = ValidatedModule.validate(config)
    end

    test "validates empty string as missing" do
      config = %ValidatedModule{name: ""}
      assert {:error, [{:name, "is required"}]} = ValidatedModule.validate(config)
    end
  end

  describe "JSON export" do
    defmodule ExportableModule do
      use Sykli.Module

      @version "2.0.0"

      param(:image, :string, required: true, doc: "Image name")
      param(:tags, {:list, :string}, default: [])

      requires([:docker, :k8s])
    end

    test "exports module definition to JSON" do
      json = ExportableModule.to_json()

      assert json["version"] == "2.0.0"
      assert json["requires"] == ["docker", "k8s"]
      assert length(json["params"]) == 2

      image_param = Enum.find(json["params"], &(&1["name"] == "image"))
      assert image_param["type"] == "string"
      assert image_param["required"] == true
      assert image_param["doc"] == "Image name"

      tags_param = Enum.find(json["params"], &(&1["name"] == "tags"))
      assert tags_param["type"] == "list<string>"
      assert tags_param["default"] == []
    end
  end

  describe "module group extraction" do
    defmodule Deeply.Nested.Docker.BuildAndPush do
      use Sykli.Module

      param(:image, :string, required: true)

      requires([])
    end

    test "extracts parent module as group" do
      # "Sykli.ModuleTest.Deeply.Nested.Docker.BuildAndPush" -> "docker"
      assert Deeply.Nested.Docker.BuildAndPush.__module__(:group) == "docker"
    end
  end
end
