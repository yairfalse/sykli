defmodule Sykli.GitHub.Source.Real do
  @moduledoc "Git-backed GitHub source acquisition."

  @behaviour Sykli.GitHub.Source.Behaviour

  alias Sykli.Services.SecretMasker

  @base_dir Path.join(System.tmp_dir!(), "sykli-runs")

  @impl true
  def acquire(%{repo: repo, head_sha: sha} = context, token, opts \\ []) do
    run_id =
      Map.get(context, :run_id) || Keyword.get(opts, :run_id) || Map.get(context, :delivery_id)

    root = Path.join(@base_dir, safe_segment(run_id || sha))
    repo_dir = Path.join(root, "repo")

    with :ok <- ensure_contained(root),
         :ok <- remove_tree(root),
         :ok <- File.mkdir_p(root),
         :ok <- clone(repo, repo_dir, token, opts),
         :ok <- checkout(repo, repo_dir, sha, token, opts) do
      {:ok, repo_dir}
    else
      {:error, %Sykli.Error{} = error} ->
        cleanup(root, opts)
        {:error, error}

      {:error, reason} ->
        cleanup(root, opts)

        {:error,
         source_error("github.source.clone_failed", "failed to acquire GitHub source", reason)}
    end
  end

  @impl true
  def cleanup(path, opts \\ [])

  def cleanup(path, _opts) when is_binary(path) do
    case run_root(path) do
      {:ok, root} ->
        remove_tree(root)

      :error ->
        :ok
    end
  end

  def cleanup(_path, _opts), do: :ok

  defp clone(repo, repo_dir, token, opts) do
    url = repo_url(repo)

    case git(repo, token, ["clone", "--depth", "1", url, repo_dir], opts) do
      {_out, 0} ->
        :ok

      {out, code} ->
        {:error,
         source_error(
           "github.source.clone_failed",
           "git clone failed",
           %{exit_code: code, output: SecretMasker.mask_string(out, [token])}
         )}
    end
  end

  defp checkout(repo, repo_dir, sha, token, opts) do
    case System.cmd("git", ["-C", repo_dir, "checkout", sha], stderr_to_stdout: true) do
      {_out, 0} ->
        :ok

      {_out, _code} ->
        fetch_and_checkout(repo, repo_dir, sha, token, opts)
    end
  end

  defp fetch_and_checkout(repo, repo_dir, sha, token, opts) do
    with {_out, 0} <-
           git(repo, token, ["-C", repo_dir, "fetch", "--depth", "1", "origin", sha], opts),
         {_out, 0} <- System.cmd("git", ["-C", repo_dir, "checkout", sha], stderr_to_stdout: true) do
      :ok
    else
      {out, code} ->
        {:error,
         source_error(
           "github.source.checkout_failed",
           "git checkout failed",
           %{exit_code: code, output: SecretMasker.mask_string(out, [token])}
         )}
    end
  end

  defp git(repo, token, args, opts) do
    runner = Keyword.get(opts, :git_runner, &System.cmd/3)

    with_git_auth_config(repo, token, fn auth_config ->
      runner.("git", args, stderr_to_stdout: true, env: git_auth_env(auth_config))
    end)
  end

  defp with_git_auth_config(repo, token, fun) do
    path =
      Path.join(System.tmp_dir!(), "sykli-git-auth-#{System.unique_integer([:positive])}.config")

    try do
      File.write!(path, git_auth_config(repo, token))
      File.chmod(path, 0o600)
      fun.(path)
    after
      File.rm(path)
    end
  end

  defp git_auth_config(repo, token) do
    """
    [http "#{repo_url(repo)}"]
        extraheader = Authorization: Bearer #{token}
    """
  end

  defp git_auth_env(auth_config) do
    [
      {"GIT_CONFIG_GLOBAL", auth_config}
    ]
  end

  defp repo_url(repo), do: "https://github.com/#{repo}.git"

  defp run_root(path) do
    expanded = Path.expand(path)
    base = Path.expand(@base_dir)

    if expanded == base or String.starts_with?(expanded, base <> "/") do
      [_empty, rest] = String.split(expanded, base, parts: 2)
      segment = rest |> String.trim_leading("/") |> String.split("/", parts: 2) |> List.first()

      if segment in [nil, ""] do
        :error
      else
        {:ok, Path.join(base, segment)}
      end
    else
      :error
    end
  end

  defp ensure_contained(path) do
    expanded = Path.expand(path)
    base = Path.expand(@base_dir)

    if String.starts_with?(expanded, base <> "/") do
      :ok
    else
      {:error, source_error("github.source.path_escape", "source path escaped temp directory")}
    end
  end

  defp safe_segment(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9._-]/, "-")
  end

  defp remove_tree(path) do
    case File.rm_rf(path) do
      {:ok, _files} -> :ok
      {:error, file, reason} -> {:error, {file, reason}}
    end
  end

  defp source_error(code, message, cause \\ nil) do
    %Sykli.Error{
      code: code,
      type: :runtime,
      message: message,
      step: :setup,
      cause: cause,
      hints: []
    }
  end
end
