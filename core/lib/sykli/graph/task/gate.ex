defmodule Sykli.Graph.Task.Gate do
  @moduledoc """
  Gate metadata for approval gates.

  A gate is a non-executing task that pauses the pipeline until
  an approval signal is received.
  """

  defstruct [:strategy, :timeout, :message, :env_var, :file_path]

  @type strategy :: :prompt | :env | :file | :webhook
  @type t :: %__MODULE__{
    strategy: strategy(),
    timeout: pos_integer(),
    message: String.t() | nil,
    env_var: String.t() | nil,
    file_path: String.t() | nil
  }

  @default_timeout 3600

  def from_map(nil), do: nil
  def from_map(map) when is_map(map) do
    strategy = case map["strategy"] do
      "prompt" -> :prompt
      "env" -> :env
      "file" -> :file
      "webhook" -> :webhook
      nil -> :prompt
      _ -> :prompt
    end

    %__MODULE__{
      strategy: strategy,
      timeout: map["timeout"] || @default_timeout,
      message: map["message"],
      env_var: map["env_var"],
      file_path: map["file_path"]
    }
  end

  def to_map(nil), do: nil
  def to_map(%__MODULE__{} = gate) do
    %{
      "strategy" => Atom.to_string(gate.strategy),
      "timeout" => gate.timeout
    }
    |> maybe_put("message", gate.message)
    |> maybe_put("env_var", gate.env_var)
    |> maybe_put("file_path", gate.file_path)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
