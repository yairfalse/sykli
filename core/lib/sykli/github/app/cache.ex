defmodule Sykli.GitHub.App.Cache do
  @moduledoc "ETS cache for GitHub installation tokens."

  @table :sykli_github_installation_tokens

  def get(installation_id, now_seconds) do
    ensure_table()

    case :ets.lookup(@table, to_string(installation_id)) do
      [{_id, token, expires_at}] when expires_at - 300 > now_seconds ->
        {:ok, token, expires_at}

      _ ->
        :miss
    end
  end

  def put(installation_id, token, expires_at) do
    ensure_table()
    true = :ets.insert(@table, {to_string(installation_id), token, expires_at})
    :ok
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
