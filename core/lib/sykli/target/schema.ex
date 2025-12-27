defmodule Sykli.Target.Schema do
  @moduledoc """
  Declarative schema system for Target configurations.

  Enables type-safe, validated, portable target configurations.

  ## Usage

      defmodule MyTarget.Schema do
        use Sykli.Target.Schema

        @schema_version "1.0.0"

        field :namespace, :string, required: true, doc: "K8s namespace"
        field :replicas, :integer, default: 1

        embed :resources do
          field :cpu, :k8s_cpu, default: "500m"
          field :memory, :k8s_memory, default: "512Mi"
        end

        validate :namespace, &validate_k8s_name/1
      end

  ## Supported Types

  - `:string` - Binary string
  - `:integer` - Integer
  - `:boolean` - Boolean
  - `:atom` - Atom
  - `:k8s_cpu` - Kubernetes CPU format (e.g., "500m", "2")
  - `:k8s_memory` - Kubernetes memory format (e.g., "512Mi", "1Gi")
  - `{:list, type}` - List of type
  - `{:map, key_type, value_type}` - Map with typed keys/values
  """

  @type field_type ::
          :string
          | :integer
          | :boolean
          | :atom
          | :k8s_cpu
          | :k8s_memory
          | {:list, field_type()}
          | {:map, field_type(), field_type()}

  @type field_opts :: [
          required: boolean(),
          default: any(),
          doc: String.t()
        ]

  @type validation_error :: {atom(), String.t()}

  # ===========================================================================
  # MACRO: use Sykli.Target.Schema
  # ===========================================================================

  defmacro __using__(_opts) do
    quote do
      import Sykli.Target.Schema, only: [field: 2, field: 3, embed: 2, embed: 3, validates: 2, capabilities: 1]

      Module.register_attribute(__MODULE__, :schema_fields, accumulate: true)
      Module.register_attribute(__MODULE__, :schema_embeds, accumulate: true)
      Module.register_attribute(__MODULE__, :schema_validators, accumulate: true)
      Module.register_attribute(__MODULE__, :schema_version, [])
      Module.register_attribute(__MODULE__, :schema_capabilities, [])

      @before_compile Sykli.Target.Schema
    end
  end

  # ===========================================================================
  # DSL MACROS
  # ===========================================================================

  @doc "Define a typed field in the schema"
  defmacro field(name, type, opts \\ []) do
    quote do
      @schema_fields {unquote(name), unquote(type), unquote(opts)}
    end
  end

  @doc "Define an embedded schema"
  defmacro embed(name, opts \\ [], do: block) do
    quote do
      # Create anonymous module for embed
      embed_module = Module.concat(__MODULE__, Macro.camelize(to_string(unquote(name))))

      # Define the embed module with its own schema
      defmodule embed_module do
        use Sykli.Target.Schema
        unquote(block)
      end

      @schema_embeds {unquote(name), embed_module, unquote(opts)}
    end
  end

  @doc "Define a custom validator for a field"
  defmacro validates(field_name, validator) do
    # Store the validator AST (escaped), not the evaluated function
    quote do
      @schema_validators {unquote(field_name), unquote(Macro.escape(validator))}
    end
  end

  @doc "Declare capabilities this target provides"
  defmacro capabilities(caps) when is_list(caps) do
    quote do
      @schema_capabilities unquote(caps)
    end
  end

  # ===========================================================================
  # COMPILE-TIME GENERATION
  # ===========================================================================

  defmacro __before_compile__(env) do
    fields = Module.get_attribute(env.module, :schema_fields) |> Enum.reverse()
    embeds = Module.get_attribute(env.module, :schema_embeds) |> Enum.reverse()
    validators = Module.get_attribute(env.module, :schema_validators) |> Enum.reverse()
    version = Module.get_attribute(env.module, :schema_version) || "0.0.0"
    caps = Module.get_attribute(env.module, :schema_capabilities) || []

    field_names = Enum.map(fields, fn {name, _, _} -> name end)
    embed_names = Enum.map(embeds, fn {name, _, _} -> name end)
    all_names = field_names ++ embed_names

    required_fields =
      (fields
       |> Enum.filter(fn {_, _, opts} -> Keyword.get(opts, :required, false) end)
       |> Enum.map(fn {name, _, _} -> name end)) ++
        (embeds
         |> Enum.filter(fn {_, _, opts} -> Keyword.get(opts, :required, false) end)
         |> Enum.map(fn {name, _, _} -> name end))

    defaults =
      fields
      |> Enum.filter(fn {_, _, opts} -> Keyword.has_key?(opts, :default) end)
      |> Enum.map(fn {name, _, opts} -> {name, Keyword.get(opts, :default)} end)

    types = Enum.map(fields, fn {name, type, _} -> {name, type} end)

    docs =
      (fields
       |> Enum.filter(fn {_, _, opts} -> Keyword.has_key?(opts, :doc) end)
       |> Enum.map(fn {name, _, opts} -> {name, Keyword.get(opts, :doc)} end)) ++
        (embeds
         |> Enum.filter(fn {_, _, opts} -> Keyword.has_key?(opts, :doc) end)
         |> Enum.map(fn {name, _, opts} -> {name, Keyword.get(opts, :doc)} end))

    embed_modules = Enum.map(embeds, fn {name, mod, _} -> {name, mod} end)

    # Build struct definition
    struct_fields =
      Enum.map(fields, fn {name, _, opts} ->
        {name, Keyword.get(opts, :default)}
      end) ++
        Enum.map(embeds, fn {name, _, _} ->
          {name, nil}
        end)

    quote do
      defstruct unquote(Macro.escape(struct_fields))

      def __schema__(:fields), do: unquote(all_names)
      def __schema__(:field_names), do: unquote(field_names)
      def __schema__(:embeds), do: unquote(embed_names)
      def __schema__(:required), do: unquote(required_fields)
      def __schema__(:version), do: unquote(version)
      def __schema__(:capabilities), do: unquote(caps)

      def __schema__(:type, field) do
        unquote(Macro.escape(types))[field]
      end

      def __schema__(:default, field) do
        unquote(Macro.escape(defaults))[field]
      end

      def __schema__(:doc, field) do
        unquote(Macro.escape(docs))[field]
      end

      def __schema__(:embed, name) do
        unquote(Macro.escape(embed_modules))[name]
      end

      # Generate validator lookup - can't escape anonymous functions, so we generate clauses
      unquote(
        validators
        |> Enum.map(fn {field, validator} ->
          quote do
            def __schema__(:validator, unquote(field)), do: unquote(validator)
          end
        end)
      )

      def __schema__(:validator, _), do: nil
      def __schema__(:validator_fields), do: unquote(Enum.map(validators, fn {f, _} -> f end))

      def __schema__(:fields_meta) do
        unquote(Macro.escape(fields))
      end

      def __schema__(:embeds_meta) do
        unquote(Macro.escape(embeds))
      end
    end
  end

  # ===========================================================================
  # VALIDATION API
  # ===========================================================================

  @doc "Validate config against schema, returns :ok or {:error, errors}"
  @spec validate(module(), map()) :: :ok | {:error, [validation_error()]}
  def validate(schema_module, config) when is_map(config) do
    errors =
      validate_required(schema_module, config) ++
        validate_types(schema_module, config) ++
        validate_embeds(schema_module, config) ++
        validate_custom(schema_module, config)

    case errors do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp validate_required(schema_module, config) do
    schema_module.__schema__(:required)
    |> Enum.reject(fn field -> Map.has_key?(config, field) end)
    |> Enum.map(fn field -> {field, "is required"} end)
  end

  defp validate_types(schema_module, config) do
    schema_module.__schema__(:field_names)
    |> Enum.flat_map(fn field ->
      case Map.fetch(config, field) do
        {:ok, value} ->
          type = schema_module.__schema__(:type, field)
          validate_type(field, value, type)

        :error ->
          []
      end
    end)
  end

  defp validate_type(_field, value, :string) when is_binary(value), do: []
  defp validate_type(field, _, :string), do: [{field, "must be a string"}]

  defp validate_type(_field, value, :integer) when is_integer(value), do: []
  defp validate_type(field, _, :integer), do: [{field, "must be an integer"}]

  defp validate_type(_field, value, :boolean) when is_boolean(value), do: []
  defp validate_type(field, _, :boolean), do: [{field, "must be a boolean"}]

  defp validate_type(_field, value, :atom) when is_atom(value), do: []
  defp validate_type(field, _, :atom), do: [{field, "must be an atom"}]

  defp validate_type(field, value, :k8s_cpu) when is_binary(value) do
    if valid_k8s_cpu?(value), do: [], else: [{field, "invalid CPU format (use e.g., '500m' or '2')"}]
  end

  defp validate_type(field, _, :k8s_cpu), do: [{field, "must be a string"}]

  defp validate_type(field, value, :k8s_memory) when is_binary(value) do
    if valid_k8s_memory?(value),
      do: [],
      else: [{field, "invalid memory format (use e.g., '512Mi' or '1Gi')"}]
  end

  defp validate_type(field, _, :k8s_memory), do: [{field, "must be a string"}]

  defp validate_type(field, value, {:list, inner_type}) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} ->
      validate_type(:"#{field}[#{index}]", item, inner_type)
    end)
  end

  defp validate_type(field, _, {:list, _}), do: [{field, "must be a list"}]

  defp validate_type(_field, value, {:map, _key_type, _value_type}) when is_map(value), do: []
  defp validate_type(field, _, {:map, _, _}), do: [{field, "must be a map"}]

  defp validate_type(_field, _value, nil), do: []

  defp validate_embeds(schema_module, config) do
    schema_module.__schema__(:embeds)
    |> Enum.flat_map(fn embed_name ->
      embed_module = schema_module.__schema__(:embed, embed_name)

      case Map.fetch(config, embed_name) do
        {:ok, embed_config} when is_map(embed_config) ->
          case validate(embed_module, embed_config) do
            :ok ->
              []

            {:error, errors} ->
              Enum.map(errors, fn {field, msg} ->
                {:"#{embed_name}.#{field}", msg}
              end)
          end

        {:ok, _} ->
          [{embed_name, "must be a map"}]

        :error ->
          []
      end
    end)
  end

  defp validate_custom(schema_module, config) do
    schema_module.__schema__(:validator_fields)
    |> Enum.flat_map(fn field ->
      validator = schema_module.__schema__(:validator, field)

      case Map.fetch(config, field) do
        {:ok, value} ->
          case validator.(value) do
            :ok -> []
            {:error, msg} -> [{field, msg}]
          end

        :error ->
          []
      end
    end)
  end

  # K8s format validators
  defp valid_k8s_cpu?(value) do
    Regex.match?(~r/^(\d+\.?\d*)(m)?$/, value)
  end

  defp valid_k8s_memory?(value) do
    Regex.match?(~r/^\d+(Ki|Mi|Gi|Ti|Pi|Ei)?$/, value)
  end

  # ===========================================================================
  # STRUCT CREATION
  # ===========================================================================

  @doc "Create a validated struct from config"
  @spec new(module(), map()) :: {:ok, struct()} | {:error, [validation_error()]}
  def new(schema_module, config) when is_map(config) do
    case validate(schema_module, config) do
      :ok ->
        struct = build_struct(schema_module, config)
        {:ok, struct}

      {:error, _} = error ->
        error
    end
  end

  defp build_struct(schema_module, config) do
    # Start with defaults
    base = struct(schema_module)

    # Apply field values
    base =
      schema_module.__schema__(:field_names)
      |> Enum.reduce(base, fn field, acc ->
        case Map.fetch(config, field) do
          {:ok, value} -> Map.put(acc, field, value)
          :error -> acc
        end
      end)

    # Apply embed values
    schema_module.__schema__(:embeds)
    |> Enum.reduce(base, fn embed_name, acc ->
      embed_module = schema_module.__schema__(:embed, embed_name)

      embed_config =
        case Map.fetch(config, embed_name) do
          {:ok, cfg} -> cfg
          :error -> %{}
        end

      {:ok, embed_struct} = new(embed_module, embed_config)
      Map.put(acc, embed_name, embed_struct)
    end)
  end

  # ===========================================================================
  # PORTABILITY: EXPORT/IMPORT
  # ===========================================================================

  @doc "Export config to JSON-serializable map"
  @spec export(module(), struct()) :: map()
  def export(schema_module, config) do
    caps = schema_module.__schema__(:capabilities)
    caps_strings = Enum.map(caps, &to_string/1)

    base = %{
      "$schema" => "sykli.target.schema/v1",
      "$type" => to_string(schema_module),
      "$version" => schema_module.__schema__(:version),
      "$capabilities" => caps_strings
    }

    # Export fields
    fields =
      schema_module.__schema__(:field_names)
      |> Enum.reduce(%{}, fn field, acc ->
        value = Map.get(config, field)
        Map.put(acc, to_string(field), value)
      end)

    # Export embeds
    embeds =
      schema_module.__schema__(:embeds)
      |> Enum.reduce(%{}, fn embed_name, acc ->
        embed_module = schema_module.__schema__(:embed, embed_name)
        embed_value = Map.get(config, embed_name)

        exported_embed =
          if embed_value do
            export_embed(embed_module, embed_value)
          else
            nil
          end

        Map.put(acc, to_string(embed_name), exported_embed)
      end)

    Map.merge(base, Map.merge(fields, embeds))
  end

  defp export_embed(schema_module, config) do
    schema_module.__schema__(:field_names)
    |> Enum.reduce(%{}, fn field, acc ->
      value = Map.get(config, field)
      Map.put(acc, to_string(field), value)
    end)
  end

  @doc "Import config from JSON map"
  @spec import(module(), map()) :: {:ok, struct()} | {:error, [validation_error()]}
  def import(schema_module, json) when is_map(json) do
    # Convert string keys to atoms
    config = atomize_keys(json, schema_module)
    new(schema_module, config)
  end

  defp atomize_keys(map, schema_module) do
    fields = schema_module.__schema__(:field_names)
    embeds = schema_module.__schema__(:embeds)

    map
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      atom_key =
        cond do
          is_atom(key) -> key
          String.starts_with?(key, "$") -> nil
          true -> String.to_existing_atom(key)
        end

      cond do
        atom_key == nil ->
          acc

        atom_key in fields ->
          Map.put(acc, atom_key, value)

        atom_key in embeds ->
          embed_module = schema_module.__schema__(:embed, atom_key)
          Map.put(acc, atom_key, atomize_keys(value, embed_module))

        true ->
          acc
      end
    end)
  rescue
    ArgumentError -> %{}
  end

  # ===========================================================================
  # INTROSPECTION
  # ===========================================================================

  @doc "Get schema version"
  @spec version(module()) :: String.t()
  def version(schema_module) do
    schema_module.__schema__(:version)
  end

  @doc "Get field documentation"
  @spec docs(module()) :: map()
  def docs(schema_module) do
    fields = schema_module.__schema__(:field_names)
    embeds = schema_module.__schema__(:embeds)

    (fields ++ embeds)
    |> Enum.reduce(%{}, fn name, acc ->
      case schema_module.__schema__(:doc, name) do
        nil -> acc
        doc -> Map.put(acc, name, doc)
      end
    end)
  end

  @doc "Describe schema structure"
  @spec describe(module()) :: map()
  def describe(schema_module) do
    fields_meta = schema_module.__schema__(:fields_meta)
    embeds_meta = schema_module.__schema__(:embeds_meta)

    fields =
      Enum.map(fields_meta, fn {name, type, opts} ->
        %{
          name: name,
          type: type,
          required: Keyword.get(opts, :required, false),
          default: Keyword.get(opts, :default),
          doc: Keyword.get(opts, :doc)
        }
      end)

    embed_fields =
      Enum.map(embeds_meta, fn {name, module, opts} ->
        %{
          name: name,
          type: :embed,
          module: module,
          required: Keyword.get(opts, :required, false),
          doc: Keyword.get(opts, :doc)
        }
      end)

    %{
      version: schema_module.__schema__(:version),
      fields: fields ++ embed_fields
    }
  end

  # ===========================================================================
  # CAPABILITIES
  # ===========================================================================

  @doc "Get capabilities declared by a schema"
  @spec get_capabilities(module()) :: [atom()]
  def get_capabilities(schema_module) do
    schema_module.__schema__(:capabilities)
  end

  @doc "Check if schema has a specific capability"
  @spec has_capability?(module(), atom()) :: boolean()
  def has_capability?(schema_module, capability) do
    capability in schema_module.__schema__(:capabilities)
  end

  @doc "Check if schema has all required capabilities"
  @spec check_capabilities(module(), [atom()]) :: :ok | {:missing, [atom()]}
  def check_capabilities(schema_module, required) when is_list(required) do
    available = MapSet.new(schema_module.__schema__(:capabilities))
    required_set = MapSet.new(required)
    missing = MapSet.difference(required_set, available) |> MapSet.to_list()

    case missing do
      [] -> :ok
      list -> {:missing, Enum.sort(list)}
    end
  end
end
