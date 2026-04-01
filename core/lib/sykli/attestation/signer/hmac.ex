defmodule Sykli.Attestation.Signer.HMAC do
  @moduledoc """
  HMAC-SHA256 signer for DSSE attestation envelopes.

  Uses a shared secret key for signing and verification.

  ## Key resolution order

  1. `:key` option passed directly
  2. `SYKLI_ATTESTATION_KEY_FILE` env var — reads key from file (recommended for production)
  3. `SYKLI_SIGNING_KEY` env var — key as plaintext (development only)
  4. `Application.get_env(:sykli, :signing_key)` — application config

  ## Usage

      {:ok, envelope} = Envelope.wrap(attestation)
      {:ok, signed} = Envelope.sign(envelope, HMAC, key: "my-secret")

  Or with key file (recommended):

      # export SYKLI_ATTESTATION_KEY_FILE=/run/secrets/signing_key
      {:ok, signed} = Envelope.sign(envelope, HMAC)

  Or with env var (development):

      # export SYKLI_SIGNING_KEY=my-secret
      {:ok, signed} = Envelope.sign(envelope, HMAC)
  """

  @behaviour Sykli.Attestation.Signer

  @impl true
  def sign(pae, opts) do
    case resolve_key(opts) do
      {:ok, key} ->
        sig = :crypto.mac(:hmac, :sha256, key, pae)
        {:ok, sig, "hmac-sha256"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def verify(pae, sig, _keyid, opts) do
    case resolve_key(opts) do
      {:ok, key} ->
        expected = :crypto.mac(:hmac, :sha256, key, pae)
        # Constant-time comparison to prevent timing attacks
        byte_size(expected) == byte_size(sig) and :crypto.hash_equals(expected, sig)

      {:error, _} ->
        false
    end
  end

  require Logger

  defp resolve_key(opts) do
    key =
      Keyword.get(opts, :key) ||
        read_key_file() ||
        read_env_key() ||
        Application.get_env(:sykli, :signing_key)

    case key do
      nil -> {:error, :no_signing_key}
      "" -> {:error, :no_signing_key}
      k when is_binary(k) -> {:ok, k}
      _ -> {:error, :invalid_signing_key}
    end
  end

  defp read_key_file do
    case System.get_env("SYKLI_ATTESTATION_KEY_FILE") do
      nil ->
        nil

      "" ->
        nil

      path ->
        case File.read(path) do
          {:ok, content} ->
            String.trim(content)

          {:error, reason} ->
            Logger.warning("[HMAC] failed to read key file #{path}: #{inspect(reason)}")
            nil
        end
    end
  end

  defp read_env_key do
    case System.get_env("SYKLI_SIGNING_KEY") do
      nil ->
        nil

      "" ->
        nil

      key ->
        if System.get_env("CI") != nil or System.get_env("SYKLI_ENV") == "production" do
          Logger.warning(
            "[HMAC] SYKLI_SIGNING_KEY env var used in CI/production — " <>
              "prefer SYKLI_ATTESTATION_KEY_FILE for secure key storage"
          )
        end

        key
    end
  end
end
