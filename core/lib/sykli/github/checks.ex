defmodule Sykli.GitHub.Checks do
  @moduledoc "GitHub Checks API facade."

  @behaviour Sykli.GitHub.Checks.Behaviour

  @impl true
  def create_suite(context, token, opts \\ []) do
    impl =
      Keyword.get(opts, :impl, Application.get_env(:sykli, :github_checks_impl, __MODULE__.Real))

    impl.create_suite(context, token, opts)
  end

  def create_suite(repo, head_sha, token, opts) when is_binary(repo) and is_binary(head_sha),
    do: create_suite(%{repo: repo, head_sha: head_sha}, token, opts)

  @impl true
  def create_run(context, token, opts \\ []) do
    impl =
      Keyword.get(opts, :impl, Application.get_env(:sykli, :github_checks_impl, __MODULE__.Real))

    impl.create_run(context, token, opts)
  end

  def create_run(repo, head_sha, token, opts) when is_binary(repo) and is_binary(head_sha),
    do: create_run(%{repo: repo, head_sha: head_sha}, token, opts)

  @impl true
  def update_run(context, token, attrs, opts \\ []) do
    impl =
      Keyword.get(opts, :impl, Application.get_env(:sykli, :github_checks_impl, __MODULE__.Real))

    impl.update_run(context, token, attrs, opts)
  end

  def update_run(repo, check_run_id, attrs, token, opts)
      when is_binary(repo) and is_integer(check_run_id),
      do: update_run(%{repo: repo, check_run_id: check_run_id}, token, attrs, opts)
end
