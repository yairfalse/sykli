defmodule Sykli.Graph.Task.CredentialBinding do
  @moduledoc """
  OIDC credential binding for cloud provider authentication.
  """

  defstruct [
    :provider,
    :role_arn,
    :project_number,
    :pool_id,
    :provider_id,
    :tenant_id,
    :client_id,
    :duration,
    :audience
  ]

  @type provider :: :aws | :gcp | :azure
  @type t :: %__MODULE__{
          provider: provider(),
          role_arn: String.t() | nil,
          project_number: String.t() | nil,
          pool_id: String.t() | nil,
          provider_id: String.t() | nil,
          tenant_id: String.t() | nil,
          client_id: String.t() | nil,
          duration: pos_integer(),
          audience: String.t() | nil
        }

  @default_duration 3600

  def from_map(nil), do: nil

  def from_map(map) when is_map(map) do
    provider =
      case map["provider"] do
        "aws" -> :aws
        "gcp" -> :gcp
        "azure" -> :azure
        _ -> nil
      end

    if is_nil(provider),
      do: nil,
      else: %__MODULE__{
        provider: provider,
        role_arn: map["role_arn"],
        project_number: map["project_number"],
        pool_id: map["pool_id"],
        provider_id: map["provider_id"],
        tenant_id: map["tenant_id"],
        client_id: map["client_id"],
        duration: map["duration"] || @default_duration,
        audience: map["audience"]
      }
  end

  def to_map(nil), do: nil

  def to_map(%__MODULE__{} = cb) do
    %{"provider" => Atom.to_string(cb.provider), "duration" => cb.duration}
    |> maybe_put("role_arn", cb.role_arn)
    |> maybe_put("project_number", cb.project_number)
    |> maybe_put("pool_id", cb.pool_id)
    |> maybe_put("provider_id", cb.provider_id)
    |> maybe_put("tenant_id", cb.tenant_id)
    |> maybe_put("client_id", cb.client_id)
    |> maybe_put("audience", cb.audience)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
