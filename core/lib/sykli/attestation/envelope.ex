defmodule Sykli.Attestation.Envelope do
  @moduledoc """
  DSSE (Dead Simple Signing Envelope) for in-toto attestations.

  Wraps an attestation payload with signatures per the DSSE spec:
  https://github.com/secure-systems-lab/dsse/blob/master/envelope.md

  ## Usage

      attestation = %{"_type" => "https://in-toto.io/Statement/v1", ...}
      {:ok, envelope} = Envelope.wrap(attestation)
      {:ok, signed} = Envelope.sign(envelope, signer)
  """

  @payload_type "application/vnd.in-toto+json"

  @type t :: %{
          String.t() => String.t() | [signature()]
        }

  @type signature :: %{String.t() => String.t()}

  @doc """
  Wraps an attestation map in a DSSE envelope (unsigned).
  """
  @spec wrap(map()) :: {:ok, map()}
  def wrap(attestation) when is_map(attestation) do
    payload = Jason.encode!(attestation)
    encoded = Base.encode64(payload)

    envelope = %{
      "payloadType" => @payload_type,
      "payload" => encoded,
      "signatures" => []
    }

    {:ok, envelope}
  end

  @doc """
  Signs a DSSE envelope using the given signer module.

  The signer must implement `Sykli.Attestation.Signer`.
  PAE is computed over the raw payload bytes (decoded from base64),
  per the DSSE spec.
  Returns `{:ok, signed_envelope}` or `{:error, reason}`.
  """
  @spec sign(map(), module(), keyword()) :: {:ok, map()} | {:error, term()}
  def sign(%{"payloadType" => ptype, "payload" => payload} = envelope, signer, opts \\ []) do
    with {:ok, raw_payload} <- Base.decode64(payload) do
      pae = pae_encode(ptype, raw_payload)

      case signer.sign(pae, opts) do
        {:ok, sig_bytes, keyid} ->
          signature = %{
            "keyid" => keyid,
            "sig" => Base.encode64(sig_bytes)
          }

          {:ok, Map.put(envelope, "signatures", [signature | envelope["signatures"]])}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Verifies a DSSE envelope signature against the given signer.
  """
  @spec verify(map(), module(), keyword()) :: :ok | {:error, term()}
  def verify(
        %{"payloadType" => ptype, "payload" => payload, "signatures" => sigs},
        signer,
        opts \\ []
      ) do
    with {:ok, raw_payload} <- Base.decode64(payload) do
      pae = pae_encode(ptype, raw_payload)

      Enum.find_value(sigs, {:error, :no_valid_signature}, fn sig ->
        case Base.decode64(sig["sig"]) do
          {:ok, sig_bytes} ->
            if signer.verify(pae, sig_bytes, sig["keyid"], opts), do: :ok

          _ ->
            nil
        end
      end)
    end
  end

  @doc """
  Decodes the payload from a DSSE envelope.
  """
  @spec decode_payload(map()) :: {:ok, map()} | {:error, term()}
  def decode_payload(%{"payload" => payload}) do
    with {:ok, json} <- Base.decode64(payload),
         {:ok, decoded} <- Jason.decode(json) do
      {:ok, decoded}
    end
  end

  # PAE (Pre-Authentication Encoding) as defined by DSSE spec:
  # "DSSEv1" + SP + len(type) + SP + type + SP + len(body) + SP + body
  # Body is the raw payload bytes (not base64-encoded).
  defp pae_encode(payload_type, payload_bytes) do
    "DSSEv1 #{byte_size(payload_type)} #{payload_type} #{byte_size(payload_bytes)} #{payload_bytes}"
  end
end
