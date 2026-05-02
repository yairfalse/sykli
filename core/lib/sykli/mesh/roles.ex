defmodule Sykli.Mesh.Roles do
  @moduledoc """
  Ephemeral single-holder-per-node registry for mesh roles.

  > **Local-only.** This registry is backed by a public ETS table on the
  > local node. It enforces "at most one holder per role *on this node*",
  > not cluster-wide uniqueness. Two nodes can both successfully `acquire/2`
  > the same role; nothing here coordinates across the cluster.
  >
  > Multi-node deployments must therefore ensure only one node carries a
  > given role label (see `Sykli.NodeProfile`). Callers that gate behavior
  > on role ownership (e.g. the GitHub webhook receiver) use
  > `held_by_local?/1` so misconfigured peers fall back to a 503/inactive
  > response rather than racing on shared work.
  """

  @table :sykli_mesh_roles

  def acquire(role, holder \\ node()) when is_atom(role) do
    ensure_table()

    case :ets.lookup(@table, role) do
      [] ->
        true = :ets.insert(@table, {role, holder})
        :ok

      [{^role, ^holder}] ->
        :ok

      [{^role, other}] ->
        {:error, {:role_held, other}}
    end
  end

  def release(role, holder \\ node()) when is_atom(role) do
    ensure_table()

    case :ets.lookup(@table, role) do
      [{^role, ^holder}] ->
        :ets.delete(@table, role)
        :ok

      [] ->
        :ok

      [{^role, other}] ->
        {:error, {:role_held, other}}
    end
  end

  def holder(role) when is_atom(role) do
    ensure_table()

    case :ets.lookup(@table, role) do
      [{^role, holder}] -> holder
      [] -> nil
    end
  end

  def held_by_local?(role), do: holder(role) == node()

  def bootstrap_local_roles do
    if Sykli.NodeProfile.has_label?("webhook_receiver") do
      acquire(:webhook_receiver)
    else
      :ok
    end
  end

  def clear do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

      _tid ->
        @table
    end
  rescue
    ArgumentError -> @table
  end
end
