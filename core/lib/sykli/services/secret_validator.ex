defmodule Sykli.Services.SecretValidator do
  @moduledoc """
  Service for validating task secrets.

  Checks that all required secrets are available before task execution.
  Secrets are resolved through the target (e.g., environment variables
  for local target, Kubernetes Secrets for K8s target).
  """

  alias Sykli.Error

  @doc """
  Validates that all required secrets for a task are present.

  Returns `:ok` if all secrets are available, or `{:error, missing_secrets}`
  with a list of missing secret names.
  """
  @spec validate(Sykli.Graph.Task.t(), map(), module()) ::
          :ok | {:error, [String.t()]}
  def validate(%Sykli.Graph.Task{secrets: nil}, _state, _target), do: :ok
  def validate(%Sykli.Graph.Task{secrets: []}, _state, _target), do: :ok

  def validate(%Sykli.Graph.Task{secrets: secrets}, state, target) do
    missing =
      secrets
      |> Enum.filter(fn name ->
        case target.resolve_secret(name, state) do
          {:ok, _} -> false
          {:error, _} -> true
        end
      end)

    if missing == [] do
      :ok
    else
      {:error, missing}
    end
  end

  @doc """
  Creates a structured error for missing secrets.
  """
  @spec missing_secrets_error(String.t(), [String.t()]) :: Sykli.Error.t()
  def missing_secrets_error(task_name, missing_secrets) do
    Error.missing_secrets(task_name, missing_secrets)
  end

  @doc """
  Resolves all secrets for a task and returns them as a map.

  This can be used to inject secrets into the task environment.
  Returns `{:ok, secrets_map}` or `{:error, missing}`.
  """
  @spec resolve_all(Sykli.Graph.Task.t(), map(), module()) ::
          {:ok, map()} | {:error, [String.t()]}
  def resolve_all(%Sykli.Graph.Task{secrets: nil}, _state, _target), do: {:ok, %{}}
  def resolve_all(%Sykli.Graph.Task{secrets: []}, _state, _target), do: {:ok, %{}}

  def resolve_all(%Sykli.Graph.Task{secrets: secrets}, state, target) do
    results =
      secrets
      |> Enum.map(fn name ->
        case target.resolve_secret(name, state) do
          {:ok, value} -> {:ok, {name, value}}
          {:error, _} -> {:error, name}
        end
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if errors == [] do
      secrets_map =
        results
        |> Enum.map(fn {:ok, {name, value}} -> {name, value} end)
        |> Map.new()

      {:ok, secrets_map}
    else
      missing = Enum.map(errors, fn {:error, name} -> name end)
      {:error, missing}
    end
  end
end
