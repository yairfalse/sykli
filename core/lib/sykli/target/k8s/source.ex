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

  # Safe character patterns for shell command arguments
  # SHA: hex characters only (40 chars full, 7+ chars short)
  @sha_pattern ~r/^[0-9a-fA-F]{7,40}$/
  # Branch: alphanumeric, /, -, _, . (no spaces or shell metacharacters)
  @branch_pattern ~r/^[a-zA-Z0-9\/_.-]+$/
  # Hostname: alphanumeric, -, . (standard DNS chars)
  @host_pattern ~r/^[a-zA-Z0-9.-]+$/
  # Path: alphanumeric, /, -, _, . (no shell metacharacters)
  @path_pattern ~r/^[a-zA-Z0-9\/_.-]+$/

  # ─────────────────────────────────────────────────────────────────────────────
  # INPUT VALIDATION (shell injection prevention)
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Validate that a value is safe for shell command interpolation.

  Returns `{:ok, value}` if safe, `{:error, reason}` otherwise.
  """
  def validate_shell_safe(value, type) when is_binary(value) do
    pattern = case type do
      :sha -> @sha_pattern
      :branch -> @branch_pattern
      :host -> @host_pattern
      :path -> @path_pattern
    end

    if Regex.match?(pattern, value) do
      {:ok, value}
    else
      {:error, {:invalid_chars, type, value}}
    end
  end

  def validate_shell_safe(nil, _type), do: {:ok, nil}

  @doc """
  Validate a git URL for shell safety.

  Accepts HTTPS and SSH URLs with safe characters.
  """
  def validate_git_url(url) when is_binary(url) do
    cond do
      # HTTPS URL
      String.starts_with?(url, "https://") ->
        # Check the rest of the URL has safe chars
        rest = String.replace_prefix(url, "https://", "")
        if Regex.match?(~r/^[a-zA-Z0-9\/_.-]+$/, rest) do
          {:ok, url}
        else
          {:error, {:invalid_url, url}}
        end

      # SSH URL
      String.starts_with?(url, "git@") ->
        # git@host:path format
        if Regex.match?(~r/^git@[a-zA-Z0-9.-]+:[a-zA-Z0-9\/_.-]+$/, url) do
          {:ok, url}
        else
          {:error, {:invalid_url, url}}
        end

      true ->
        {:error, {:invalid_url, url}}
    end
  end

  def validate_git_url(nil), do: {:ok, nil}

  # Shell-quote a string (single quotes, escaping embedded single quotes)
  defp shell_quote(nil), do: "''"
  defp shell_quote(value) when is_binary(value) do
    escaped = String.replace(value, "'", "'\"'\"'")
    "'#{escaped}'"
  end

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
    # Validate all inputs to prevent shell injection
    :ok = validate_inputs!(url, branch, sha, workspace)

    clone_parts = ["git clone"]

    clone_parts =
      if depth != :full and is_integer(depth) do
        clone_parts ++ ["--depth=#{depth}"]
      else
        clone_parts
      end

    # Use shell quoting for branch (even though validated, defense in depth)
    clone_parts =
      if branch do
        clone_parts ++ ["--branch=#{shell_quote(branch)}"]
      else
        clone_parts
      end

    # Quote URL and workspace
    clone_parts = clone_parts ++ [shell_quote(url), shell_quote(workspace)]
    clone_cmd = Enum.join(clone_parts, " ")

    # Quote workspace and sha in checkout command
    "#{clone_cmd} && cd #{shell_quote(workspace)} && git checkout #{shell_quote(sha)}"
  end

  defp build_ssh_clone_command(url, branch, sha, workspace, depth) do
    # Validate inputs first
    :ok = validate_inputs!(url, branch, sha, workspace)

    # Extract and validate host from URL for ssh-keyscan
    host =
      case GitContext.parse_remote_url(url) do
        {:ok, %{host: h}} -> h
        _ -> "github.com"
      end

    # Validate host separately
    case validate_shell_safe(host, :host) do
      {:ok, _} -> :ok
      {:error, reason} -> raise "Invalid host for ssh-keyscan: #{inspect(reason)}"
    end

    # Use shell quoting for host (defense in depth)
    ssh_setup = """
    mkdir -p ~/.ssh && \
    echo "$GIT_SSH_KEY" > ~/.ssh/id_rsa && \
    chmod 600 ~/.ssh/id_rsa && \
    ssh-keyscan #{shell_quote(host)} >> ~/.ssh/known_hosts
    """

    clone_cmd = build_simple_clone_command(url, branch, sha, workspace, depth)

    String.trim(ssh_setup) <> " && " <> clone_cmd
  end

  defp build_token_clone_command(url, branch, sha, workspace, depth) do
    # Validate base inputs
    :ok = validate_inputs!(url, branch, sha, workspace)

    # Convert URL to include token
    # https://github.com/org/repo.git → https://${GIT_TOKEN}@github.com/org/repo.git
    authed_url =
      case GitContext.parse_remote_url(url) do
        {:ok, %{host: host, owner: owner, repo: repo}} ->
          # Validate extracted components
          case validate_shell_safe(host, :host) do
            {:ok, _} -> :ok
            {:error, reason} -> raise "Invalid host in URL: #{inspect(reason)}"
          end

          case validate_shell_safe(owner, :path) do
            {:ok, _} -> :ok
            {:error, reason} -> raise "Invalid owner in URL: #{inspect(reason)}"
          end

          case validate_shell_safe(repo, :path) do
            {:ok, _} -> :ok
            {:error, reason} -> raise "Invalid repo in URL: #{inspect(reason)}"
          end

          "https://${GIT_TOKEN}@#{host}/#{owner}/#{repo}.git"

        _ ->
          raise "Cannot parse git URL for token authentication: #{url}"
      end

    # Build clone command (validation already done, authed_url is constructed safely)
    clone_parts = ["git clone"]

    clone_parts =
      if depth != :full and is_integer(depth) do
        clone_parts ++ ["--depth=#{depth}"]
      else
        clone_parts
      end

    clone_parts =
      if branch do
        clone_parts ++ ["--branch=#{shell_quote(branch)}"]
      else
        clone_parts
      end

    # Don't quote authed_url as it contains ${GIT_TOKEN} which needs shell expansion
    clone_parts = clone_parts ++ [authed_url, shell_quote(workspace)]
    clone_cmd = Enum.join(clone_parts, " ")

    "#{clone_cmd} && cd #{shell_quote(workspace)} && git checkout #{shell_quote(sha)}"
  end

  # Validate all git context inputs, raise on failure
  defp validate_inputs!(url, branch, sha, workspace) do
    case validate_git_url(url) do
      {:ok, _} -> :ok
      {:error, reason} -> raise "Invalid git URL: #{inspect(reason)}"
    end

    case validate_shell_safe(branch, :branch) do
      {:ok, _} -> :ok
      {:error, reason} -> raise "Invalid branch name: #{inspect(reason)}"
    end

    case validate_shell_safe(sha, :sha) do
      {:ok, _} -> :ok
      {:error, reason} -> raise "Invalid git SHA: #{inspect(reason)}"
    end

    case validate_shell_safe(workspace, :path) do
      {:ok, _} -> :ok
      {:error, reason} -> raise "Invalid workspace path: #{inspect(reason)}"
    end

    :ok
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
