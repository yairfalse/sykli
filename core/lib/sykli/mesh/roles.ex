defmodule Sykli.Mesh.Roles do
  @moduledoc "Ephemeral single-holder registry for mesh roles."

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
