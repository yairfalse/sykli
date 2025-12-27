defmodule Sykli.Target.SchemaTest do
  use ExUnit.Case, async: true

  alias Sykli.Target.Schema

  # =============================================================================
  # SCHEMA DEFINITION
  # =============================================================================

  describe "schema definition" do
    test "defines a simple schema with typed fields" do
      defmodule SimpleSchema do
        use Sykli.Target.Schema

        field :name, :string, required: true
        field :port, :integer, default: 8080
        field :enabled, :boolean, default: true
      end

      assert SimpleSchema.__schema__(:fields) == [:name, :port, :enabled]
      assert SimpleSchema.__schema__(:type, :name) == :string
      assert SimpleSchema.__schema__(:type, :port) == :integer
      assert SimpleSchema.__schema__(:required) == [:name]
      assert SimpleSchema.__schema__(:default, :port) == 8080
    end

    test "defines nested schemas" do
      defmodule NestedSchema do
        use Sykli.Target.Schema

        field :namespace, :string, required: true

        embed :resources do
          field :cpu, :string, default: "500m"
          field :memory, :string, default: "512Mi"
        end
      end

      assert :resources in NestedSchema.__schema__(:embeds)
      assert NestedSchema.__schema__(:embed, :resources).__schema__(:fields) == [:cpu, :memory]
    end

    test "defines list fields" do
      defmodule ListSchema do
        use Sykli.Target.Schema

        field :tags, {:list, :string}, default: []
        field :ports, {:list, :integer}
      end

      assert ListSchema.__schema__(:type, :tags) == {:list, :string}
      assert ListSchema.__schema__(:type, :ports) == {:list, :integer}
    end

    test "defines map fields" do
      defmodule MapSchema do
        use Sykli.Target.Schema

        field :labels, {:map, :string, :string}, default: %{}
        field :node_selector, {:map, :string, :string}
      end

      assert MapSchema.__schema__(:type, :labels) == {:map, :string, :string}
    end
  end

  # =============================================================================
  # VALIDATION
  # =============================================================================

  describe "validation" do
    defmodule ValidatedSchema do
      use Sykli.Target.Schema

      field :namespace, :string, required: true
      field :replicas, :integer, default: 1
      field :cpu, :k8s_cpu
      field :memory, :k8s_memory
    end

    test "validates required fields" do
      assert {:error, errors} = Schema.validate(ValidatedSchema, %{})
      assert {:namespace, "is required"} in errors
    end

    test "validates with valid data" do
      config = %{namespace: "production", replicas: 3}
      assert :ok = Schema.validate(ValidatedSchema, config)
    end

    test "validates type mismatch" do
      config = %{namespace: "prod", replicas: "three"}
      assert {:error, errors} = Schema.validate(ValidatedSchema, config)
      assert {:replicas, "must be an integer"} in errors
    end

    test "validates k8s_cpu format" do
      assert :ok = Schema.validate(ValidatedSchema, %{namespace: "x", cpu: "500m"})
      assert :ok = Schema.validate(ValidatedSchema, %{namespace: "x", cpu: "2"})
      assert :ok = Schema.validate(ValidatedSchema, %{namespace: "x", cpu: "0.5"})

      assert {:error, errors} = Schema.validate(ValidatedSchema, %{namespace: "x", cpu: "500mb"})
      assert {:cpu, msg} = Enum.find(errors, fn {k, _} -> k == :cpu end)
      assert msg =~ "invalid"
    end

    test "validates k8s_memory format" do
      assert :ok = Schema.validate(ValidatedSchema, %{namespace: "x", memory: "512Mi"})
      assert :ok = Schema.validate(ValidatedSchema, %{namespace: "x", memory: "1Gi"})
      assert :ok = Schema.validate(ValidatedSchema, %{namespace: "x", memory: "1024Ki"})

      assert {:error, errors} = Schema.validate(ValidatedSchema, %{namespace: "x", memory: "512mb"})
      assert {:memory, msg} = Enum.find(errors, fn {k, _} -> k == :memory end)
      assert msg =~ "invalid"
    end

    test "validates nested embeds" do
      defmodule EmbedValidation do
        use Sykli.Target.Schema

        field :name, :string, required: true

        embed :resources, required: true do
          field :cpu, :k8s_cpu, required: true
          field :memory, :k8s_memory, required: true
        end
      end

      # Missing embed
      assert {:error, errors} = Schema.validate(EmbedValidation, %{name: "test"})
      assert {:resources, "is required"} in errors

      # Invalid nested field
      config = %{name: "test", resources: %{cpu: "bad", memory: "512Mi"}}
      assert {:error, errors} = Schema.validate(EmbedValidation, config)
      assert {:"resources.cpu", _} = Enum.find(errors, fn {k, _} -> k == :"resources.cpu" end)

      # Valid
      config = %{name: "test", resources: %{cpu: "500m", memory: "512Mi"}}
      assert :ok = Schema.validate(EmbedValidation, config)
    end

    test "validates list elements" do
      defmodule ListValidation do
        use Sykli.Target.Schema

        field :ports, {:list, :integer}, required: true
      end

      assert :ok = Schema.validate(ListValidation, %{ports: [80, 443, 8080]})

      assert {:error, errors} = Schema.validate(ListValidation, %{ports: [80, "http", 443]})
      assert {:"ports[1]", "must be an integer"} in errors
    end
  end

  # =============================================================================
  # STRUCT CREATION
  # =============================================================================

  describe "struct creation" do
    defmodule StructSchema do
      use Sykli.Target.Schema

      field :namespace, :string, required: true
      field :replicas, :integer, default: 1
      field :debug, :boolean, default: false

      embed :resources do
        field :cpu, :string, default: "500m"
        field :memory, :string, default: "512Mi"
      end
    end

    test "creates struct with defaults" do
      {:ok, config} = Schema.new(StructSchema, %{namespace: "prod"})

      assert config.namespace == "prod"
      assert config.replicas == 1
      assert config.debug == false
      assert config.resources.cpu == "500m"
      assert config.resources.memory == "512Mi"
    end

    test "creates struct with overrides" do
      {:ok, config} = Schema.new(StructSchema, %{
        namespace: "staging",
        replicas: 3,
        resources: %{cpu: "1", memory: "1Gi"}
      })

      assert config.namespace == "staging"
      assert config.replicas == 3
      assert config.resources.cpu == "1"
      assert config.resources.memory == "1Gi"
    end

    test "returns error for invalid config" do
      assert {:error, _} = Schema.new(StructSchema, %{replicas: 3})
    end
  end

  # =============================================================================
  # PORTABILITY - EXPORT/IMPORT
  # =============================================================================

  describe "export/import" do
    defmodule PortableSchema do
      use Sykli.Target.Schema

      @schema_version "1.0.0"

      field :namespace, :string, required: true
      field :service_account, :string, default: "default"

      embed :resources do
        field :cpu, :k8s_cpu, default: "500m"
        field :memory, :k8s_memory, default: "512Mi"
      end
    end

    test "exports to JSON-serializable map" do
      {:ok, config} = Schema.new(PortableSchema, %{namespace: "production"})

      exported = Schema.export(PortableSchema, config)

      assert exported["$schema"] == "sykli.target.schema/v1"
      assert exported["$type"] == "Elixir.Sykli.Target.SchemaTest.PortableSchema"
      assert exported["$version"] == "1.0.0"
      assert exported["namespace"] == "production"
      assert exported["service_account"] == "default"
      assert exported["resources"]["cpu"] == "500m"
    end

    test "imports from JSON map" do
      json = %{
        "$schema" => "sykli.target.schema/v1",
        "$type" => "Elixir.Sykli.Target.SchemaTest.PortableSchema",
        "$version" => "1.0.0",
        "namespace" => "staging",
        "resources" => %{"cpu" => "1", "memory" => "2Gi"}
      }

      {:ok, config} = Schema.import(PortableSchema, json)

      assert config.namespace == "staging"
      assert config.resources.cpu == "1"
      assert config.resources.memory == "2Gi"
    end

    test "import validates data" do
      json = %{
        "$schema" => "sykli.target.schema/v1",
        "$type" => "Elixir.Sykli.Target.SchemaTest.PortableSchema",
        "resources" => %{"cpu" => "invalid-cpu"}
      }

      assert {:error, errors} = Schema.import(PortableSchema, json)
      assert Enum.any?(errors, fn {k, _} -> k == :namespace end)
    end

    test "export produces valid JSON" do
      {:ok, config} = Schema.new(PortableSchema, %{namespace: "prod"})
      exported = Schema.export(PortableSchema, config)

      # Should be JSON-encodable
      assert {:ok, json_string} = Jason.encode(exported)
      assert is_binary(json_string)

      # Round-trip
      {:ok, decoded} = Jason.decode(json_string)
      {:ok, reimported} = Schema.import(PortableSchema, decoded)
      assert reimported.namespace == config.namespace
    end
  end

  # =============================================================================
  # INTROSPECTION
  # =============================================================================

  describe "introspection" do
    defmodule IntrospectableSchema do
      use Sykli.Target.Schema

      @moduledoc "A test schema for introspection"
      @schema_version "2.1.0"

      field :namespace, :string, required: true, doc: "Kubernetes namespace"
      field :replicas, :integer, default: 1, doc: "Number of replicas"

      embed :resources, doc: "Resource limits" do
        field :cpu, :k8s_cpu, default: "500m", doc: "CPU request/limit"
        field :memory, :k8s_memory, default: "512Mi", doc: "Memory request/limit"
      end
    end

    test "returns schema version" do
      assert Schema.version(IntrospectableSchema) == "2.1.0"
    end

    test "returns field documentation" do
      docs = Schema.docs(IntrospectableSchema)

      assert docs[:namespace] == "Kubernetes namespace"
      assert docs[:replicas] == "Number of replicas"
      assert docs[:resources] == "Resource limits"
    end

    test "describes schema structure" do
      description = Schema.describe(IntrospectableSchema)

      assert description.version == "2.1.0"
      assert length(description.fields) == 3
      assert Enum.find(description.fields, &(&1.name == :namespace)).required == true
      assert Enum.find(description.fields, &(&1.name == :replicas)).default == 1
    end
  end

  # =============================================================================
  # CUSTOM VALIDATORS
  # =============================================================================

  describe "custom validators" do
    defmodule CustomValidation do
      use Sykli.Target.Schema

      field :port, :integer, required: true
      field :namespace, :string, required: true

      validates :port, fn port ->
        if port > 0 and port < 65536 do
          :ok
        else
          {:error, "must be between 1 and 65535"}
        end
      end

      # Inline validator for namespace (function refs don't work at macro expansion time)
      validates :namespace, fn name ->
        if Regex.match?(~r/^[a-z0-9][a-z0-9-]*[a-z0-9]$/, name) do
          :ok
        else
          {:error, "must be a valid Kubernetes name (lowercase alphanumeric and dashes)"}
        end
      end
    end

    test "runs custom validators" do
      assert :ok = Schema.validate(CustomValidation, %{port: 8080, namespace: "my-app"})

      assert {:error, errors} = Schema.validate(CustomValidation, %{port: 99999, namespace: "my-app"})
      assert {:port, "must be between 1 and 65535"} in errors

      assert {:error, errors} = Schema.validate(CustomValidation, %{port: 80, namespace: "My_App"})
      assert {:namespace, msg} = Enum.find(errors, fn {k, _} -> k == :namespace end)
      assert msg =~ "Kubernetes name"
    end
  end

  # =============================================================================
  # CAPABILITIES
  # =============================================================================

  describe "capabilities" do
    defmodule CapableTarget do
      use Sykli.Target.Schema

      @schema_version "1.0.0"

      capabilities [:secrets, :storage, :services]

      field :namespace, :string, required: true
    end

    defmodule BasicTarget do
      use Sykli.Target.Schema

      field :name, :string, required: true
      # No capabilities declared - defaults to empty
    end

    test "declares capabilities" do
      assert Schema.get_capabilities(CapableTarget) == [:secrets, :storage, :services]
    end

    test "defaults to empty capabilities" do
      assert Schema.get_capabilities(BasicTarget) == []
    end

    test "checks single capability" do
      assert Schema.has_capability?(CapableTarget, :secrets) == true
      assert Schema.has_capability?(CapableTarget, :gpu) == false
    end

    test "checks multiple capabilities" do
      assert Schema.check_capabilities(CapableTarget, [:secrets, :storage]) == :ok
      assert {:missing, [:gpu]} = Schema.check_capabilities(CapableTarget, [:secrets, :gpu])
      assert {:missing, [:gpu, :spot]} = Schema.check_capabilities(CapableTarget, [:gpu, :spot])
    end

    test "exports capabilities in portable format" do
      {:ok, config} = Schema.new(CapableTarget, %{namespace: "prod"})
      exported = Schema.export(CapableTarget, config)

      assert exported["$capabilities"] == ["secrets", "storage", "services"]
    end
  end
end
