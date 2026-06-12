defmodule Sykli.Daemon.SessionStore do
  @moduledoc """
  Local persistence for daemon coordinator session metadata.

  The store intentionally does not persist the coordinator token. Tokens must
  come from the environment, one-shot CLI flags, or a future secret store.
  """

  @session_version 1

  def path(opts \\ []) do
    base = Keyword.get(opts, :path) || Path.join([File.cwd!(), ".sykli"])
    Path.join([base, "daemon", "session.json"])
  end

  def write(session, opts \\ []) when is_map(session) do
    path = path(opts)
    data = Map.put(session, "version", @session_version)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, Jason.encode!(data, pretty: true)),
         :ok <- restrict_permissions(path) do
      {:ok, data}
    end
  end

  def read(opts \\ []) do
    path = path(opts)

    with {:ok, body} <- File.read(path),
         {:ok, data} <- Jason.decode(body),
         :ok <- validate(data) do
      {:ok, data}
    else
      {:error, :enoent} -> {:error, :daemon_session_not_found}
      {:error, %Jason.DecodeError{}} -> {:error, :daemon_session_malformed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate(%{"version" => @session_version, "session_id" => id})
       when is_binary(id) and id != "",
       do: :ok

  defp validate(_data), do: {:error, :daemon_session_invalid}

  @doc """
  Remove the persisted session. Removing an absent session is `:ok` —
  leave is idempotent.
  """
  def delete(opts \\ []) do
    case File.rm(path(opts)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp restrict_permissions(path) do
    case :file.change_mode(String.to_charlist(path), 0o600) do
      :ok -> :ok
      {:error, :enoent} -> {:error, :enoent}
      {:error, _reason} -> :ok
    end
  end
end
