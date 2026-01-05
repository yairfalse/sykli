defmodule Sykli.Target.K8s.Source do
  @moduledoc """
  Source code mounting strategies for Kubernetes Jobs.

  When running tasks in K8s, source code must be available in the Pod.
  This module provides strategies for getting source code into Jobs:

  - `:git_clone` - Clone from git (default, works everywhere)
  - `:pvc` - Mount from PersistentVolumeClaim (faster, requires infra)

  ## Example

      # Build init container for git clone
      git_ctx = GitContext.detect(".")
      init = Source.build_init_container(git_ctx, depth: 1)

      # Add to Job manifest
      %{
        "spec" => %{
          "template" => %{
            "spec" => %{
              "initContainers" => [init],
              "volumes" => [Source.workspace_volume()]
            }
          }
        }
      }
  """

  alias Sykli.GitContext

  @default_git_image "alpine/git:latest"
  @default_workspace "/workspace"

  # ─────────────────────────────────────────────────────────────────────────────
  # STRATEGY
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Get the source mounting strategy from options.

  Returns `:git_clone` (default) or `:pvc`.
  """
  @spec strategy(keyword()) :: :git_clone | :pvc
  def strategy(opts) do
    Keyword.get(opts, :source_strategy, :git_clone)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # VALIDATION
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Validate git context for K8s use.

  Returns `:ok` or `{:error, :dirty_workdir}` if the workdir has uncommitted changes.
  Use `allow_dirty: true` to skip this check.
  """
  @spec validate_git_context(GitContext.t(), keyword()) :: :ok | {:error, :dirty_workdir}
  def validate_git_context(ctx, opts \\ []) do
    allow_dirty = Keyword.get(opts, :allow_dirty, false)

    if ctx.dirty and not allow_dirty do
      {:error, :dirty_workdir}
    else
      :ok
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # INIT CONTAINER
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Build an init container that clones source code.

  ## Options

  - `:depth` - Clone depth (default: 1, use `:full` for full clone)
  - `:git_ssh_secret` - K8s Secret name containing SSH private key
  - `:git_token_secret` - K8s Secret name containing HTTPS token
  - `:git_image` - Custom git image (default: alpine/git:latest)
  - `:workspace` - Mount path for source (default: /workspace)

  ## Returns

  A map representing the init container spec for a K8s Job.
  """
  @spec build_init_container(GitContext.t(), keyword()) :: map()
  def build_init_container(git_ctx, opts \\ []) do
    workspace = Keyword.get(opts, :workspace, @default_workspace)
    git_image = Keyword.get(opts, :git_image, @default_git_image)
    ssh_secret = Keyword.get(opts, :git_ssh_secret)
    token_secret = Keyword.get(opts, :git_token_secret)

    # Build the clone command
    command = build_clone_command(git_ctx, opts, ssh_secret, token_secret)

    container = %{
      "name" => "git-clone",
      "image" => git_image,
      "command" => ["sh", "-c", command],
      "volumeMounts" => [
        %{"name" => "workspace", "mountPath" => workspace}
      ]
    }

    # Add environment variables for secrets
    container = add_secret_env(container, ssh_secret, token_secret)

    container
  end

  defp build_clone_command(git_ctx, opts, ssh_secret, token_secret) do
    depth = Keyword.get(opts, :depth, 1)
    workspace = Keyword.get(opts, :workspace, @default_workspace)

    url = git_ctx.url
    branch = git_ctx.branch
    sha = git_ctx.sha

    cond do
      # SSH authentication
      ssh_secret != nil ->
        build_ssh_clone_command(url, branch, sha, workspace, depth)

      # Token authentication
      token_secret != nil ->
        build_token_clone_command(url, branch, sha, workspace, depth)

      # No auth (public repo)
      true ->
        build_simple_clone_command(url, branch, sha, workspace, depth)
    end
  end

  defp build_simple_clone_command(url, branch, sha, workspace, depth) do
    clone_parts = ["git clone"]

    clone_parts =
      if depth != :full and is_integer(depth) do
        clone_parts ++ ["--depth=#{depth}"]
      else
        clone_parts
      end

    clone_parts =
      if branch do
        clone_parts ++ ["--branch=#{branch}"]
      else
        clone_parts
      end

    clone_parts = clone_parts ++ [url, workspace]
    clone_cmd = Enum.join(clone_parts, " ")

    "#{clone_cmd} && cd #{workspace} && git checkout #{sha}"
  end

  defp build_ssh_clone_command(url, branch, sha, workspace, depth) do
    # Extract host from URL for ssh-keyscan
    host =
      case GitContext.parse_remote_url(url) do
        {:ok, %{host: h}} -> h
        _ -> "github.com"
      end

    ssh_setup = """
    mkdir -p ~/.ssh && \
    echo "$GIT_SSH_KEY" > ~/.ssh/id_rsa && \
    chmod 600 ~/.ssh/id_rsa && \
    ssh-keyscan #{host} >> ~/.ssh/known_hosts
    """

    clone_cmd = build_simple_clone_command(url, branch, sha, workspace, depth)

    String.trim(ssh_setup) <> " && " <> clone_cmd
  end

  defp build_token_clone_command(url, branch, sha, workspace, depth) do
    # Convert URL to include token
    # https://github.com/org/repo.git → https://${GIT_TOKEN}@github.com/org/repo.git
    authed_url =
      case GitContext.parse_remote_url(url) do
        {:ok, %{host: host, owner: owner, repo: repo}} ->
          "https://${GIT_TOKEN}@#{host}/#{owner}/#{repo}.git"

        _ ->
          # Fallback: try simple replacement
          String.replace(url, "https://", "https://${GIT_TOKEN}@")
      end

    build_simple_clone_command(authed_url, branch, sha, workspace, depth)
  end

  defp add_secret_env(container, ssh_secret, token_secret) do
    env = []

    env =
      if ssh_secret do
        [
          %{
            "name" => "GIT_SSH_KEY",
            "valueFrom" => %{
              "secretKeyRef" => %{
                "name" => ssh_secret,
                "key" => "id_rsa"
              }
            }
          }
          | env
        ]
      else
        env
      end

    env =
      if token_secret do
        [
          %{
            "name" => "GIT_TOKEN",
            "valueFrom" => %{
              "secretKeyRef" => %{
                "name" => token_secret,
                "key" => "token"
              }
            }
          }
          | env
        ]
      else
        env
      end

    if length(env) > 0 do
      Map.put(container, "env", env)
    else
      container
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # VOLUMES
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Returns the workspace volume definition (emptyDir).

  This volume is shared between the init container (git clone) and
  the main task container.
  """
  @spec workspace_volume() :: map()
  def workspace_volume do
    %{
      "name" => "workspace",
      "emptyDir" => %{}
    }
  end

  @doc """
  Returns a volume mount for the workspace.

  ## Arguments

  - `path` - Mount path (default: "/workspace")
  """
  @spec workspace_mount(String.t()) :: map()
  def workspace_mount(path \\ @default_workspace) do
    %{
      "name" => "workspace",
      "mountPath" => path
    }
  end
end
