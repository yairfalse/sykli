defprotocol Sykli.Target.Protocol.Secrets do
  @moduledoc """
  Protocol for secret resolution.

  Defines how targets resolve secrets (sensitive values like API keys,
  passwords, etc.) for use in task execution.

  - Local target: reads from environment variables
  - K8s target: reads from Kubernetes Secrets
  """

  @doc """
  Resolves a secret value by name.

  Returns `{:ok, value}` if the secret is found, or `{:error, :not_found}` if not.
  """
  @spec resolve(t(), String.t()) :: {:ok, String.t()} | {:error, :not_found | :not_supported}
  def resolve(target, name)
end

# Default implementation that returns not supported
defimpl Sykli.Target.Protocol.Secrets, for: Any do
  def resolve(_target, _name), do: {:error, :not_supported}
end
