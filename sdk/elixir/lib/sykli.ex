defmodule Sykli do
  @moduledoc """
  CI pipelines defined in Elixir instead of YAML.

  ## DSL Usage

      use Sykli

      pipeline do
        task "test" do
          run "mix test"
          inputs ["**/*.ex", "mix.exs"]
        end

        task "lint" do
          run "mix credo --strict"
        end

        task "build" do
          run "mix compile"
          after_ ["test", "lint"]
        end
      end

  ## Dynamic pipelines

  Since it's real Elixir, you can use variables, loops, and conditionals:

      pipeline do
        services = ["api", "web", "worker"]

        for svc <- services do
          task "test-\#{svc}" do
            run "mix test apps/\#{svc}"
          end
        end

        task "deploy" do
          run "./deploy.sh"
          after_ Enum.map(services, &"test-\#{&1}")
          when_ "branch == 'main'"
        end
      end

  ## With containers

      pipeline do
        task "test" do
          container "elixir:1.16"
          workdir "/app"
          run "mix test"
        end
      end
  """

  # ============================================================================
  # USE MACRO - Sets up the DSL
  # ============================================================================

  defmacro __using__(_opts) do
    quote do
      import Sykli, only: [pipeline: 1]
      import Sykli.DSL
    end
  end

  # ============================================================================
  # PIPELINE MACRO
  # ============================================================================

  @doc """
  Defines a CI pipeline.

  The block can contain `task` definitions and regular Elixir code.
  Automatically emits JSON when run with `--emit` flag.
  """
  defmacro pipeline(do: block) do
    quote do
      # Initialize empty pipeline in process dictionary
      Process.put(:sykli_tasks, [])
      Process.put(:sykli_resources, %{})

      # Execute the block (task macros will register themselves)
      unquote(block)

      # Collect results
      tasks = Process.get(:sykli_tasks) |> Enum.reverse()
      resources = Process.get(:sykli_resources)

      # Clean up
      Process.delete(:sykli_tasks)
      Process.delete(:sykli_resources)

      # Build pipeline struct
      pipeline = %Sykli.Pipeline{
        tasks: tasks,
        resources: resources
      }

      # Emit if --emit flag present
      if "--emit" in System.argv() do
        pipeline
        |> Sykli.Emitter.validate!()
        |> Sykli.Emitter.to_json()
        |> IO.puts()

        System.halt(0)
      end

      pipeline
    end
  end
end
