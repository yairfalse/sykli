defmodule Sykli.ContractLock do
  @moduledoc """
  `sykli.lock` encoding and verification.
  """

  alias Sykli.ContractHash
  alias Sykli.Error

  @version "1"
  @filename "sykli.lock"

  def filename, do: @filename

  def build(contract, sdk_file) when is_map(contract) and is_binary(sdk_file) do
    %{
      "version" => @version,
      "contract_hash" => ContractHash.from_contract(contract),
      "schema_version" => to_string(contract["version"] || ""),
      "sdk_file" => Path.basename(sdk_file),
      "contract" => contract
    }
  end

  def encode(lock) when is_map(lock) do
    case verify_integrity(lock) do
      :ok -> {:ok, Jason.encode!(canonicalize(lock)) <> "\n"}
      {:error, error} -> {:error, error}
    end
  end

  def decode(bytes, path \\ @filename) when is_binary(bytes) do
    with {:ok, lock} <- Jason.decode(bytes),
         true <- is_map(lock) || {:error, :not_object},
         :ok <- verify_integrity(lock) do
      {:ok, lock}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, Error.contract_lock_corrupt(path, reason)}
      false -> {:error, Error.contract_lock_corrupt(path, :not_object)}
    end
  end

  def read(path) do
    case File.read(path) do
      {:ok, bytes} -> decode(bytes, path)
      {:error, reason} -> {:error, Error.contract_lock_corrupt(path, reason)}
    end
  end

  def write(lock, path) do
    with {:ok, bytes} <- encode(lock),
         :ok <- File.write(path, bytes) do
      {:ok, bytes}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, Error.contract_lock_corrupt(path, reason)}
    end
  end

  def lock_path_for_sdk(sdk_file), do: Path.join(Path.dirname(sdk_file), @filename)

  def verify_integrity(lock) when is_map(lock) do
    case integrity_reason(lock) do
      :ok -> :ok
      {:error, reason} -> {:error, Error.contract_lock_corrupt(@filename, reason)}
    end
  end

  defp integrity_reason(lock) do
    with :ok <- require_keys(lock),
         true <- lock["version"] == @version || {:error, :unsupported_lock_version},
         true <- is_map(lock["contract"]) || {:error, :missing_contract},
         hash <- ContractHash.from_contract(lock["contract"]),
         true <- lock["contract_hash"] == hash || {:error, :internal_hash_mismatch} do
      :ok
    end
  end

  def verify_contract(contract, lock) when is_map(contract) and is_map(lock) do
    with :ok <- verify_integrity(lock),
         hash <- ContractHash.from_contract(contract),
         true <- hash == lock["contract_hash"] || {:error, hash} do
      :ok
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, actual_hash} when is_binary(actual_hash) ->
        {:error, Error.contract_lock_mismatch(lock["contract_hash"], actual_hash)}
    end
  end

  def double_emit(emit_fun) when is_function(emit_fun, 0) do
    with {:ok, first_json} <- emit_fun.(),
         {:ok, first} <- decode_contract(first_json),
         {:ok, second_json} <- emit_fun.(),
         {:ok, second} <- decode_contract(second_json),
         first_hash <- ContractHash.from_contract(first),
         second_hash <- ContractHash.from_contract(second),
         true <-
           first_hash == second_hash || {:error, {:nondeterministic, first_hash, second_hash}} do
      {:ok, %{contract: first, hash: first_hash}}
    else
      {:error, {:nondeterministic, first_hash, second_hash}} ->
        {:error, Error.contract_nondeterministic(first_hash, second_hash)}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, Error.wrap(reason)}
    end
  end

  def verify_project(path, opts \\ []) do
    with {:ok, {sdk_file, _runner} = sdk} <- detector(opts).find(path) do
      lock_path = lock_path_for_sdk(sdk_file)

      if File.exists?(lock_path) do
        with {:ok, lock} <- read(lock_path),
             {:ok, current} <- double_emit(fn -> emit(opts, sdk) end),
             :ok <- verify_contract(current.contract, lock) do
          {:ok, %{hash: current.hash, lock_path: lock_path}}
        else
          {:error, %Error{} = error} -> {:error, error}
        end
      else
        :ok
      end
    else
      {:error, reason} -> {:error, Error.wrap(reason)}
    end
  end

  defp emit(opts, sdk) do
    case Keyword.get(opts, :emit_fun) do
      fun when is_function(fun, 1) -> fun.(sdk)
      _ -> detector(opts).emit(sdk)
    end
  end

  defp detector(opts), do: Keyword.get(opts, :detector, Sykli.Detector)

  defp decode_contract(json) do
    case Jason.decode(json) do
      {:ok, contract} when is_map(contract) -> {:ok, contract}
      {:ok, _} -> {:error, :invalid_format}
      {:error, reason} -> {:error, {:json_parse_error, reason}}
    end
  end

  defp require_keys(lock) do
    missing =
      ["version", "contract_hash", "schema_version", "sdk_file", "contract"]
      |> Enum.reject(&Map.has_key?(lock, &1))

    if missing == [], do: :ok, else: {:error, {:missing_keys, missing}}
  end

  defp canonicalize(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> {key, canonicalize(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)
  defp canonicalize(value), do: value
end
