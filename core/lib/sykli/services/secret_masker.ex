defmodule Sykli.Services.SecretMasker do
  @moduledoc """
  Masks known secret values in strings and data structures.

  Used to prevent secrets from leaking into occurrence logs,
  webhook payloads, or CLI output.
  """

  @mask "***MASKED***"
  @min_secret_length 4

  @doc """
  Replace known secret values in a string with a mask.
  Secrets shorter than #{@min_secret_length} chars are ignored to avoid false positives.
  """
  @spec mask_string(term(), [String.t()]) :: term()
  def mask_string(str, _secrets) when not is_binary(str), do: str
  def mask_string(str, []), do: str

  def mask_string(str, secrets) do
    secrets
    |> Enum.filter(&(is_binary(&1) and byte_size(&1) >= @min_secret_length))
    |> Enum.reduce(str, fn secret, acc ->
      String.replace(acc, secret, @mask)
    end)
  end

  @doc """
  Recursively mask secret values in maps, lists, and strings.
  """
  @spec mask_deep(term(), [String.t()]) :: term()
  def mask_deep(data, []), do: data
  def mask_deep(data, secrets) when is_binary(data), do: mask_string(data, secrets)

  def mask_deep(data, secrets) when is_map(data) do
    Map.new(data, fn {k, v} -> {k, mask_deep(v, secrets)} end)
  end

  def mask_deep(data, secrets) when is_list(data) do
    Enum.map(data, &mask_deep(&1, secrets))
  end

  def mask_deep(data, _secrets), do: data
end
