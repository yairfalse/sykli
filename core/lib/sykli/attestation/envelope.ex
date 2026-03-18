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
          payloadType: String.t(),
          payload: String.t(),
          signatures: [signature()]
        }

  @type signature :: %{keyid: String.t(), sig: String.t()}

  @doc """
  Wraps an attestation map in a DSSE envelope (unsigned).
  """
  @spec wrap(map()) :: {:ok, map()}
  def wrap(attestation) when is_map(attestation) do
    payload = Jason.encode!(attestation)
    encoded = Base.url_encode64(payload, padding: false)

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
  Returns `{:ok, signed_envelope}` or `{:error, reason}`.
  """
  @spec sign(map(), module(), keyword()) :: {:ok, map()} | {:error, term()}
  def sign(%{"payloadType" => ptype, "payload" => payload} = envelope, signer, opts \\ []) do
    # DSSE PAE (Pre-Authentication Encoding)
    pae = pae_encode(ptype, payload)

    case signer.sign(pae, opts) do
      {:ok, sig_bytes, keyid} ->
        signature = %{
          "keyid" => keyid,
          "sig" => Base.url_encode64(sig_bytes, padding: false)
        }

        {:ok, Map.put(envelope, "signatures", [signature | envelope["signatures"]])}

      {:error, reason} ->
        {:error, reason}
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
    pae = pae_encode(ptype, payload)

    Enum.find_value(sigs, {:error, :no_valid_signature}, fn sig ->
      case Base.url_decode64(sig["sig"], padding: false) do
        {:ok, sig_bytes} ->
          if signer.verify(pae, sig_bytes, sig["keyid"], opts), do: :ok

        _ ->
          nil
      end
    end)
  end

  @doc """
  Decodes the payload from a DSSE envelope.
  """
  @spec decode_payload(map()) :: {:ok, map()} | {:error, term()}
  def decode_payload(%{"payload" => payload}) do
    with {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, decoded} <- Jason.decode(json) do
      {:ok, decoded}
    end
  end

  # PAE (Pre-Authentication Encoding) as defined by DSSE spec:
  # "DSSEv1" + SP + len(type) + SP + type + SP + len(body) + SP + body
  defp pae_encode(payload_type, payload) do
    "DSSEv1 #{byte_size(payload_type)} #{payload_type} #{byte_size(payload)} #{payload}"
  end
end
