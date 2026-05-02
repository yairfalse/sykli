defmodule Sykli.GitHub.Checks.Fake do
  @moduledoc "Fake GitHub Checks client for tests."

  @behaviour Sykli.GitHub.Checks.Behaviour

  @impl true
  def create_suite(context, token, opts \\ []) do
    notify(opts, {:github_checks_create_suite, context, token})
    response(opts, :create_suite_response, {:ok, %{"id" => 10_001}})
  end

  @impl true
  def create_run(context, token, opts \\ []) do
    notify(opts, {:github_checks_create_run, context, token, Keyword.get(opts, :name)})

    case response(opts, :create_run_response, :default) do
      :default ->
        name = Keyword.get(opts, :name, "sykli")
        {:ok, %{"id" => run_id_for(name), "name" => name}}

      other ->
        other
    end
  end

  @impl true
  def update_run(context, token, attrs, opts \\ []) do
    notify(opts, {:github_checks_update_run, context, token, attrs})
    response(opts, :update_run_response, {:ok, %{"id" => context.check_run_id}})
  end

  defp run_id_for(name), do: 20_000 + :erlang.phash2(name, 10_000)

  defp response(opts, key, default), do: Keyword.get(opts, key, default)

  defp notify(opts, message) do
    case Keyword.get(opts, :test_pid) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end
end
