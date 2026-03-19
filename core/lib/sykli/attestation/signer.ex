defmodule Sykli.Attestation.Signer do
  @moduledoc """
  Behaviour for attestation signing implementations.

  Implementations:
  - `Sykli.Attestation.Signer.HMAC` — HMAC-SHA256 with a shared key
  - Future: `Sykli.Attestation.Signer.Sigstore` — keyless signing via Fulcio/Rekor
  """

  @doc """
  Signs the PAE-encoded payload.
  Returns `{:ok, signature_bytes, keyid}` or `{:error, reason}`.
  """
  @callback sign(pae :: binary(), opts :: keyword()) ::
              {:ok, sig :: binary(), keyid :: String.t()} | {:error, term()}

  @doc """
  Verifies a signature against the PAE-encoded payload.
  """
  @callback verify(pae :: binary(), sig :: binary(), keyid :: String.t(), opts :: keyword()) ::
              boolean()
end
