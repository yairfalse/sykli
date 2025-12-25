defmodule Sykli.Target.Lifecycle do
  @moduledoc """
  Optional capability: Setup and teardown around pipeline execution.

  Implement this if your target needs to:
  - Initialize connections or resources before running
  - Clean up after the pipeline completes
  - Maintain state across task executions

  ## Example

      defmodule MyTarget do
        @behaviour Sykli.Target
        @behaviour Sykli.Target.Lifecycle

        defstruct [:connection]

        @impl Sykli.Target.Lifecycle
        def setup(opts) do
          conn = connect_to_something(opts[:url])
          {:ok, %__MODULE__{connection: conn}}
        end

        @impl Sykli.Target.Lifecycle
        def teardown(state) do
          close_connection(state.connection)
          :ok
        end

        @impl Sykli.Target
        def run_task(task, opts) do
          state = opts[:state]
          # Use state.connection
        end
      end

  ## Without Lifecycle

  If you don't implement Lifecycle, the executor will pass `nil` as state
  and skip setup/teardown. This is fine for stateless targets.
  """

  @doc """
  Initialize the target before pipeline execution.

  Called once at the start. Return `{:ok, state}` where state
  is passed to all subsequent `run_task/2` calls via `opts[:state]`.
  """
  @callback setup(opts :: keyword()) :: {:ok, state :: term()} | {:error, term()}

  @doc """
  Clean up after pipeline execution.

  Called once at the end, even if the pipeline failed.
  Receives the state from `setup/1`.
  """
  @callback teardown(state :: term()) :: :ok
end
