defmodule Sykli.Attestation.Signer.HMAC do
  @moduledoc """
  HMAC-SHA256 signer for DSSE attestation envelopes.

  Uses a shared secret key for signing and verification.
  The key is read from `SYKLI_SIGNING_KEY` env var or
  `Application.get_env(:sykli, :signing_key)`.

  ## Usage

      {:ok, envelope} = Envelope.wrap(attestation)
      {:ok, signed} = Envelope.sign(envelope, HMAC, key: "my-secret")

  Or with env var:

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

  defp resolve_key(opts) do
    key =
      Keyword.get(opts, :key) ||
        System.get_env("SYKLI_SIGNING_KEY") ||
        Application.get_env(:sykli, :signing_key)

    case key do
      nil -> {:error, :no_signing_key}
      "" -> {:error, :no_signing_key}
      k when is_binary(k) -> {:ok, k}
      _ -> {:error, :invalid_signing_key}
    end
  end
end
