defmodule Sykli.Target.Secrets do
  @moduledoc """
  Optional capability: Resolve secrets by name.

  Implement this if your target can provide secret values
  (API keys, tokens, passwords) to tasks.

  ## Example

      defmodule MyTarget do
        @behaviour Sykli.Target
        @behaviour Sykli.Target.Secrets

        @impl Sykli.Target.Secrets
        def resolve_secret(name, _state) do
          # Fetch from Vault, env, K8s Secret, etc.
          case Vault.read("secret/" <> name) do
            {:ok, value} -> {:ok, value}
            :not_found -> {:error, :not_found}
          end
        end
      end

  ## Built-in Implementations

  SYKLI provides reusable secret providers you can delegate to:

      defmodule MyTarget do
        @behaviour Sykli.Target
        @behaviour Sykli.Target.Secrets

        # Delegate to environment variables
        defdelegate resolve_secret(name, state), to: Sykli.Secrets.Env
      end

  ## Without Secrets

  If you don't implement Secrets, tasks that require secrets will fail.
  The executor checks for this capability before attempting to resolve.
  """

  @doc """
  Resolve a secret value by name.

  ## Parameters

  - `name` - The secret name (e.g., "GITHUB_TOKEN", "DB_PASSWORD")
  - `state` - Target state from setup (or nil if no Lifecycle)

  ## Returns

  - `{:ok, value}` - The secret value
  - `{:error, :not_found}` - Secret doesn't exist
  """
  @callback resolve_secret(name :: String.t(), state :: term()) ::
              {:ok, String.t()} | {:error, :not_found}
end

# ─────────────────────────────────────────────────────────────────────────────
# Built-in secret providers
# ─────────────────────────────────────────────────────────────────────────────

defmodule Sykli.Secrets.Env do
  @moduledoc """
  Resolve secrets from environment variables.

  This is the simplest secret provider - just reads from the environment.

  ## Usage

      defmodule MyTarget do
        @behaviour Sykli.Target.Secrets

        defdelegate resolve_secret(name, state), to: Sykli.Secrets.Env
      end
  """

  def resolve_secret(name, _state) do
    case System.get_env(name) do
      nil -> {:error, :not_found}
      "" -> {:error, :not_found}
      value -> {:ok, value}
    end
  end
end
