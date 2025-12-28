defmodule Sykli.Module do
  @moduledoc """
  Reusable pipeline components - the Orb killer.

  Modules are native packages that encapsulate common CI patterns.
  Define once in Elixir, generate for Go/Rust/TypeScript.

  ## Philosophy

  - DRY: Define patterns once, use everywhere
  - Abstracted: Hide complexity, expose clean interfaces
  - Portable: Works across projects, teams, languages
  - Hand-holding: If users need docs to understand output, we failed

  ## Usage

      defmodule Sykli.Modules.Docker.BuildAndPush do
        use Sykli.Module

        @moduledoc "Docker build and push patterns"
        @version "1.0.0"

        param :image, :string, required: true, doc: "Image name with tag"
        param :dockerfile, :string, default: "Dockerfile"
        param :push, :boolean, default: true

        requires [:docker]

        tasks do
          task "build" do
            container "docker:24-dind"
            run build_command()
          end

          if params().push do
            task "push" do
              container "docker:24-dind"
              run "docker push \#{params().image}"
              after_ ["build"]
            end
          end
        end
      end

  ## Output Grouping

  When modules run, output is grouped for clarity:

      ── docker ──
      ▶ build   docker build -t myapp .
      ▶ push    docker push myapp
      ✓ build   (12s)
      ✓ push    (3s)

  No cryptic prefixes. Just what's happening.
  """

  # ===========================================================================
  # TYPES
  # ===========================================================================

  @type param_type ::
          :string
          | :integer
          | :boolean
          | {:list, param_type()}
          | {:map, param_type(), param_type()}

  @type param_opts :: [
          required: boolean(),
          default: any(),
          doc: String.t()
        ]

  @type capability :: atom()

  # ===========================================================================
  # MACRO: use Sykli.Module
  # ===========================================================================

  defmacro __using__(_opts) do
    quote do
      import Sykli.Module,
        only: [param: 2, param: 3, requires: 1, tasks: 1]

      Module.register_attribute(__MODULE__, :module_params, accumulate: true)
      Module.register_attribute(__MODULE__, :module_requires, [])
      Module.register_attribute(__MODULE__, :module_tasks_block, [])
      Module.register_attribute(__MODULE__, :module_version, [])

      @before_compile Sykli.Module
    end
  end

  # ===========================================================================
  # DSL MACROS
  # ===========================================================================

  @doc """
  Define a parameter that users must/can provide.

  ## Examples

      param :image, :string, required: true, doc: "Image name"
      param :dockerfile, :string, default: "Dockerfile"
      param :build_args, {:map, :string, :string}, default: %{}
  """
  defmacro param(name, type, opts \\ []) do
    quote do
      @module_params {unquote(name), unquote(type), unquote(opts)}
    end
  end

  @doc """
  Declare capabilities this module requires from the target.

  ## Examples

      requires [:docker]
      requires [:k8s, :secrets]
  """
  defmacro requires(capabilities) when is_list(capabilities) do
    quote do
      @module_requires unquote(capabilities)
    end
  end

  @doc """
  Define the tasks this module creates.

  Inside the block, you have access to `params()` which returns
  the user-provided parameters.

  ## Examples

      tasks do
        task "build" do
          run "docker build -t \#{params().image} ."
        end
      end
  """
  defmacro tasks(do: block) do
    quote do
      @module_tasks_block unquote(Macro.escape(block))
    end
  end

  # ===========================================================================
  # COMPILE-TIME GENERATION
  # ===========================================================================

  defmacro __before_compile__(env) do
    params = Module.get_attribute(env.module, :module_params) |> Enum.reverse()
    requires = Module.get_attribute(env.module, :module_requires) || []
    _tasks_block = Module.get_attribute(env.module, :module_tasks_block)
    version = Module.get_attribute(env.module, :version) || "0.1.0"

    # Extract module name for grouping (e.g., "Docker" from "Sykli.Modules.Docker.BuildAndPush")
    module_group = extract_module_group(env.module)

    # Generate struct fields from params (just field names with nil defaults for struct)
    struct_fields =
      params
      |> Enum.map(fn {name, _type, _opts} -> {name, nil} end)

    # Build lookup tables
    types = Enum.map(params, fn {name, type, _} -> {name, type} end)
    defaults = Enum.map(params, fn {name, _, opts} -> {name, Keyword.get(opts, :default)} end)
    docs = Enum.map(params, fn {name, _, opts} -> {name, Keyword.get(opts, :doc, "")} end)

    required_params =
      params
      |> Enum.filter(fn {_, _, opts} -> Keyword.get(opts, :required, false) end)
      |> Enum.map(fn {name, _, _} -> name end)

    quote do
      # The struct users instantiate
      defstruct unquote(Macro.escape(struct_fields))

      @doc "Module version"
      def __module__(:version), do: unquote(version)

      @doc "Module group name for output grouping"
      def __module__(:group), do: unquote(module_group)

      @doc "Required capabilities"
      def __module__(:requires), do: unquote(requires)

      @doc "Parameter specifications"
      def __module__(:params), do: unquote(Macro.escape(params))

      @doc "Required parameter names"
      def __module__(:required_params), do: unquote(required_params)

      @doc "Get param type"
      def __param__(name, :type), do: unquote(Macro.escape(types))[name]

      @doc "Get param default"
      def __param__(name, :default), do: unquote(Macro.escape(defaults))[name]

      @doc "Get param doc"
      def __param__(name, :doc), do: unquote(Macro.escape(docs))[name]

      @doc "Check if param is required"
      def __param__(name, :required), do: name in unquote(required_params)

      @doc """
      Validate the module configuration.

      Returns `:ok` or `{:error, reasons}`.
      """
      def validate(%__MODULE__{} = config) do
        errors =
          unquote(Macro.escape(params))
          |> Enum.flat_map(fn {name, _type, opts} ->
            if Keyword.get(opts, :required, false) do
              value = Map.get(config, name)

              if is_nil(value) or value == "" do
                [{name, "is required"}]
              else
                []
              end
            else
              []
            end
          end)

        case errors do
          [] -> :ok
          _ -> {:error, errors}
        end
      end

      @doc """
      Generate tasks from this module configuration.

      Returns a list of task structs that can be added to a pipeline.
      """
      def tasks(%__MODULE__{} = config) do
        # Apply defaults
        config = apply_defaults(config)

        # Validate
        case validate(config) do
          :ok -> generate_tasks(config)
          {:error, errors} -> raise ArgumentError, format_errors(errors)
        end
      end

      # Apply default values to config
      defp apply_defaults(%__MODULE__{} = config) do
        defaults =
          unquote(Macro.escape(params))
          |> Enum.map(fn {name, _type, opts} ->
            {name, Keyword.get(opts, :default)}
          end)
          |> Enum.into(%{})

        struct(config, defaults)
        |> then(fn c ->
          # Override with any explicitly set values
          Map.merge(
            c,
            Map.from_struct(config) |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()
          )
        end)
      end

      defp format_errors(errors) do
        errors
        |> Enum.map(fn {field, msg} -> "#{field} #{msg}" end)
        |> Enum.join(", ")
      end

      # The tasks block will be injected here by the module author
      # For now, provide a default that returns empty
      defp generate_tasks(_config) do
        # This gets overridden when tasks/1 macro is used
        []
      end

      @doc """
      Export module definition to JSON for cross-language use.
      """
      def to_json do
        %{
          "name" => to_string(__MODULE__),
          "group" => __module__(:group),
          "version" => __module__(:version),
          "requires" => Enum.map(__module__(:requires), &to_string/1),
          "params" =>
            __module__(:params)
            |> Enum.map(fn {name, type, opts} ->
              %{
                "name" => to_string(name),
                "type" => format_type(type),
                "required" => Keyword.get(opts, :required, false),
                "default" => Keyword.get(opts, :default),
                "doc" => Keyword.get(opts, :doc)
              }
            end)
        }
      end

      defp format_type(:string), do: "string"
      defp format_type(:integer), do: "integer"
      defp format_type(:boolean), do: "boolean"
      defp format_type({:list, inner}), do: "list<#{format_type(inner)}>"
      defp format_type({:map, k, v}), do: "map<#{format_type(k)}, #{format_type(v)}>"
      defp format_type(other), do: to_string(other)
    end
  end

  # ===========================================================================
  # HELPERS
  # ===========================================================================

  defp extract_module_group(module) do
    module
    |> Module.split()
    |> Enum.reverse()
    |> case do
      [_name, group | _] -> String.downcase(group)
      [name | _] -> String.downcase(name)
    end
  end
end
