defmodule Sykli.ULID do
  @moduledoc """
  Monotonic ULID (Universally Unique Lexicographically Sortable Identifier) generator.

  Generates ULIDs compatible with AHTI's event storage (github.com/oklog/ulid/v2).
  Uses an Agent to maintain monotonic state, ensuring that ULIDs generated within
  the same millisecond are strictly increasing.

  ## ULID Structure

  - 48-bit timestamp: milliseconds since Unix epoch (first 10 chars)
  - 80-bit randomness: monotonically incremented within same millisecond (last 16 chars)
  - Encoded as 26 characters using Crockford's Base32

  ## Monotonic Guarantee

  When generating ULIDs within the same millisecond, the randomness component
  is incremented by 1, ensuring lexicographic order equals temporal order.
  This is critical for AHTI's causality tracking and BadgerDB/Parquet storage.

  ## Example

      iex> Sykli.ULID.generate()
      "01HQGXVP00ABCDEFGHJKMNPQRS"
  """

  use Agent
  import Bitwise

  # Crockford's Base32 alphabet (excludes I, L, O, U to avoid ambiguity)
  @alphabet ~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ"

  # Maximum randomness value (80 bits)
  @max_randomness bsl(1, 80) - 1

  def start_link(_opts) do
    Agent.start_link(fn -> %{last_time: 0, last_random: 0} end, name: __MODULE__)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @doc """
  Generates a new monotonic ULID using current time.
  """
  def generate do
    timestamp = System.system_time(:millisecond)
    generate_with_timestamp(timestamp)
  end

  @doc """
  Generates a ULID with a specific timestamp (DateTime or milliseconds).
  """
  def generate_with_timestamp(%DateTime{} = dt) do
    timestamp = DateTime.to_unix(dt, :millisecond)
    generate_with_timestamp(timestamp)
  end

  def generate_with_timestamp(timestamp) when is_integer(timestamp) do
    Agent.get_and_update(__MODULE__, fn state ->
      {ulid, new_state} = generate_monotonic(timestamp, state)
      {ulid, new_state}
    end)
  end

  @doc """
  Generates a ULID without monotonic guarantees (stateless).
  """
  def generate_random do
    timestamp = System.system_time(:millisecond)
    random = :crypto.strong_rand_bytes(10) |> :binary.decode_unsigned()
    encode(timestamp, random)
  end

  @doc """
  Parses a ULID string and returns {:ok, {timestamp_ms, randomness}}.
  """
  def parse(ulid) when is_binary(ulid) and byte_size(ulid) == 26 do
    case decode(ulid) do
      {:ok, timestamp, random} -> {:ok, {timestamp, random}}
      error -> error
    end
  end

  def parse(_), do: {:error, :invalid_length}

  @doc """
  Extracts the timestamp from a ULID as a DateTime.
  """
  def timestamp(ulid) when is_binary(ulid) and byte_size(ulid) == 26 do
    case parse(ulid) do
      {:ok, {ts_ms, _}} -> {:ok, DateTime.from_unix!(ts_ms, :millisecond)}
      error -> error
    end
  end

  def timestamp(_), do: {:error, :invalid_ulid}

  @doc """
  Validates that a ULID string is properly formatted.
  """
  def valid?(ulid) when is_binary(ulid) and byte_size(ulid) == 26 do
    case parse(ulid) do
      {:ok, _} -> true
      _ -> false
    end
  end

  def valid?(_), do: false

  # --- Private Functions ---

  defp generate_monotonic(timestamp, %{last_time: last_time, last_random: last_random}) do
    cond do
      timestamp > last_time ->
        random = generate_randomness()
        ulid = encode(timestamp, random)
        {ulid, %{last_time: timestamp, last_random: random}}

      timestamp == last_time ->
        new_random = last_random + 1

        if new_random > @max_randomness do
          Process.sleep(1)

          generate_monotonic(System.system_time(:millisecond), %{
            last_time: last_time + 1,
            last_random: 0
          })
        else
          ulid = encode(timestamp, new_random)
          {ulid, %{last_time: timestamp, last_random: new_random}}
        end

      true ->
        # Clock went backwards - use last timestamp (clock skew protection)
        new_random = last_random + 1

        if new_random > @max_randomness do
          random = generate_randomness()
          {encode(last_time + 1, random), %{last_time: last_time + 1, last_random: random}}
        else
          {encode(last_time, new_random), %{last_time: last_time, last_random: new_random}}
        end
    end
  end

  defp generate_randomness do
    :crypto.strong_rand_bytes(10)
    |> :binary.decode_unsigned()
    |> band(@max_randomness)
  end

  # Encode timestamp (48 bits) and randomness (80 bits) as 26-char Crockford Base32
  defp encode(timestamp, randomness) do
    # Combine into 128-bit value: (timestamp << 80) | randomness
    value = bsl(timestamp, 80) |> bor(randomness)

    # Encode as 26 characters (MSB first)
    encode_base32(value, 26, [])
    |> List.to_string()
  end

  defp encode_base32(_value, 0, acc), do: acc

  defp encode_base32(value, remaining, acc) do
    char_index = band(value, 31)
    char = Enum.at(@alphabet, char_index)
    encode_base32(bsr(value, 5), remaining - 1, [char | acc])
  end

  # Decode 26-char Crockford Base32 to {timestamp, randomness}
  defp decode(ulid) do
    chars = String.to_charlist(ulid)

    result =
      Enum.reduce_while(chars, {:ok, 0}, fn char, {:ok, acc} ->
        case decode_char(char) do
          {:ok, value} -> {:cont, {:ok, bsl(acc, 5) |> bor(value)}}
          :error -> {:halt, {:error, :invalid_character}}
        end
      end)

    case result do
      {:ok, value} ->
        timestamp = bsr(value, 80)
        randomness = band(value, @max_randomness)
        {:ok, timestamp, randomness}

      error ->
        error
    end
  end

  defp decode_char(char) when char in ?0..?9, do: {:ok, char - ?0}
  defp decode_char(char) when char in ?A..?H, do: {:ok, char - ?A + 10}
  defp decode_char(char) when char in ?a..?h, do: {:ok, char - ?a + 10}
  defp decode_char(char) when char in ?J..?K, do: {:ok, char - ?J + 18}
  defp decode_char(char) when char in ?j..?k, do: {:ok, char - ?j + 18}
  defp decode_char(char) when char in ?M..?N, do: {:ok, char - ?M + 20}
  defp decode_char(char) when char in ?m..?n, do: {:ok, char - ?m + 20}
  defp decode_char(char) when char in ?P..?T, do: {:ok, char - ?P + 22}
  defp decode_char(char) when char in ?p..?t, do: {:ok, char - ?p + 22}
  defp decode_char(char) when char in ?V..?Z, do: {:ok, char - ?V + 27}
  defp decode_char(char) when char in ?v..?z, do: {:ok, char - ?v + 27}
  defp decode_char(_), do: :error
end
