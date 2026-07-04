defmodule Sykli.ContractHash do
  @moduledoc """
  Deterministic hashes for emitted Sykli contracts.

  Team Mode uses canonicalized emitted JSON as the local contract identity.
  This keeps formatting and comments in SDK source files out of the hash and
  avoids including runtime data such as timestamps, durations, or run ids.
  """

  @doc "Computes a sha256-prefixed hash for emitted contract JSON."
  def from_json(json) when is_binary(json) do
    with {:ok, decoded} <- Jason.decode(json) do
      {:ok, from_contract(decoded)}
    else
      {:error, reason} -> {:error, {:contract_hash_failed, :emitted_json, reason}}
    end
  end

  @doc "Computes a sha256-prefixed hash for a parsed contract."
  def from_contract(contract) when is_map(contract) do
    contract
    |> canonical_json()
    |> from_bytes()
  end

  @doc "Encodes a parsed contract in Sykli's canonical key order."
  def canonical_json(contract) when is_map(contract) do
    contract
    |> canonicalize()
    |> Jason.encode!()
  end

  # Canonicalize by recursively sorting object keys so the hash is independent of
  # map iteration order. Elixir preserves insertion order only for small maps;
  # maps with >32 keys switch to a hashed representation whose iteration order is
  # implementation-defined and not guaranteed stable across OTP versions. Two
  # semantically-identical contracts emitted with different key orders must hash
  # identically. Jason.OrderedObject encodes keys in the exact order we provide.
  defp canonicalize(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> {key, canonicalize(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)
  defp canonicalize(scalar), do: scalar

  @doc "Computes a sha256-prefixed hash for raw bytes."
  def from_bytes(bytes) when is_binary(bytes) do
    digest =
      :crypto.hash(:sha256, bytes)
      |> Base.encode16(case: :lower)

    "sha256:#{digest}"
  end
end
