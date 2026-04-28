defmodule Sykli.Mesh.Transport.Erlang do
  @moduledoc """
  Erlang distribution transport backend.
  """

  @behaviour Sykli.Mesh.Transport

  @impl true
  def list_nodes, do: raise("not implemented")

  @impl true
  def spawn_remote(_node_id, _mfa), do: raise("not implemented")

  @impl true
  def send_msg(_destination, _message), do: raise("not implemented")

  @impl true
  def monitor(_target), do: raise("not implemented")

  @impl true
  def demonitor(_reference), do: raise("not implemented")

  @impl true
  def now_ms, do: :os.system_time(:millisecond)

  @impl true
  def emit(_event), do: raise("not implemented")

  @impl true
  def subscribe(_opts), do: raise("not implemented")
end
