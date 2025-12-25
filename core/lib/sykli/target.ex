defmodule Sykli.Target do
  @moduledoc """
  The Target interface - where pipelines execute.

  A Target is simply something that can run tasks. That's it.

  ## The Minimal Interface

      defmodule MyTarget do
        @behaviour Sykli.Target

        @impl true
        def run_task(task, opts) do
          # Execute the task somehow
          # Return :ok or {:error, reason}
        end
      end

  That's all you need. One function.

  ## Optional Capabilities

  Targets can opt into additional capabilities by implementing
  optional behaviours. These are building blocks - use what you need:

  - `Sykli.Target.Lifecycle` - setup/teardown around pipeline execution
  - `Sykli.Target.Secrets` - resolve secrets by name
  - `Sykli.Target.Storage` - manage volumes and artifacts
  - `Sykli.Target.Services` - start/stop service containers

  ## Examples

  ### Simple Target (GitHub Actions)

      defmodule GitHubActionsTarget do
        @behaviour Sykli.Target

        @impl true
        def run_task(task, opts) do
          workflow = opts[:workflow] || "ci.yml"
          # Trigger workflow via GitHub API
          # Wait for completion
          # Return result
        end
      end

  ### Full-Featured Target (like K8s)

      defmodule MyK8sTarget do
        @behaviour Sykli.Target
        @behaviour Sykli.Target.Lifecycle
        @behaviour Sykli.Target.Secrets
        @behaviour Sykli.Target.Storage
        @behaviour Sykli.Target.Services

        # Implement all the callbacks...
      end

  ## Runtime Capability Checking

  The executor checks what a target supports at runtime:

      if Sykli.Target.has_capability?(target, :secrets) do
        {:ok, value} = target.resolve_secret("API_KEY", state)
      end

  """

  # ─────────────────────────────────────────────────────────────────────────────
  # THE CORE INTERFACE - Just one function
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Execute a task.

  This is the only required callback. Everything else is optional.

  ## Parameters

  - `task` - The task specification (command, container, env, etc.)
  - `opts` - Runtime options (workdir, timeout, etc.)

  ## Returns

  - `:ok` on success
  - `{:error, reason}` on failure
  """
  @callback run_task(task :: map(), opts :: keyword()) :: :ok | {:error, term()}

  # ─────────────────────────────────────────────────────────────────────────────
  # CAPABILITY CHECKING
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Check if a target module implements a capability.

  ## Capabilities

  - `:lifecycle` - Has setup/teardown
  - `:secrets` - Can resolve secrets
  - `:storage` - Can manage volumes/artifacts
  - `:services` - Can run service containers

  ## Example

      if Sykli.Target.has_capability?(MyTarget, :secrets) do
        {:ok, value} = MyTarget.resolve_secret("API_KEY", state)
      end
  """
  def has_capability?(target_module, capability) do
    behaviour = capability_behaviour(capability)
    behaviours = target_module.module_info(:attributes)[:behaviour] || []
    behaviour in behaviours
  end

  defp capability_behaviour(:lifecycle), do: Sykli.Target.Lifecycle
  defp capability_behaviour(:secrets), do: Sykli.Target.Secrets
  defp capability_behaviour(:storage), do: Sykli.Target.Storage
  defp capability_behaviour(:services), do: Sykli.Target.Services

  @doc """
  List all capabilities a target implements.
  """
  def capabilities(target_module) do
    [:lifecycle, :secrets, :storage, :services]
    |> Enum.filter(&has_capability?(target_module, &1))
  end
end
