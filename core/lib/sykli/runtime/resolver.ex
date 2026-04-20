defmodule Sykli.Runtime.Resolver do
  @moduledoc """
  Resolves `Sykli.Runtime.Behaviour` implementations via a documented priority.

  ## Container runtime priority (used when a task has a container image)

  First match wins:

  1. `opts[:runtime]` — explicit per-call override.
  2. `Application.get_env(:sykli, :default_runtime)` — when non-nil.
  3. `System.get_env("SYKLI_RUNTIME")` — shorthand names or fully-qualified
     `Elixir.X.Y.Z` module strings.
  4. Auto-detect: first of `Sykli.Runtime.Docker`, `Sykli.Runtime.Podman`
     whose `available?/0` succeeds.
  5. Fallback: `Sykli.Runtime.Shell` (warning logged once per VM boot).

  ## Containerless runtime priority (used when a task has no container image)

  First match wins:

  1. `opts[:containerless_runtime]` — explicit per-call override.
  2. `Application.get_env(:sykli, :containerless_runtime)` — when non-nil.
  3. Default: `Sykli.Runtime.Shell`.

  ## Caching

  `available?/0` probe results are cached in `:persistent_term` for the VM
  lifetime — probes are effectively static (a `docker info` shellout doesn't
  change result between calls in the same process). Tests that manipulate
  availability or env vars must call `reset/0` in setup.

  ## Test hook

  The probe can be overridden via
  `Application.put_env(:sykli, :runtime_probe, fn module -> boolean end)`
  to avoid shelling out in unit tests. See the tests for usage.
  """

  require Logger

  @shorthand %{
    "docker" => Sykli.Runtime.Docker,
    "podman" => Sykli.Runtime.Podman,
    "shell" => Sykli.Runtime.Shell,
    "fake" => Sykli.Runtime.Fake
  }

  # ─── public API ─────────────────────────────────────────────────────────

  @spec resolve(keyword) :: module
  def resolve(opts \\ []) do
    from_opts(opts, :runtime) ||
      from_app_env(:default_runtime) ||
      from_sys_env() ||
      auto_detect() ||
      fallback_to_shell()
  end

  @spec resolve_containerless(keyword) :: module
  def resolve_containerless(opts \\ []) do
    from_opts(opts, :containerless_runtime) ||
      from_app_env(:containerless_runtime) ||
      Sykli.Runtime.Shell
  end

  @spec reset() :: :ok
  def reset do
    :persistent_term.erase({__MODULE__, :probe_cache})
    :persistent_term.erase({__MODULE__, :fallback_warned})
    :ok
  end

  @doc """
  Convert a user-supplied runtime name into a runtime module.

  Accepts the same forms as `SYKLI_RUNTIME` / the CLI's `--runtime` flag:

  - `"docker"`, `"podman"`, `"shell"`, `"fake"` — shorthand names
  - `"Elixir.Fully.Qualified.Module"` — fully-qualified module atom form

  Raises `ArgumentError` for unknown names. Designed as the entry point
  for CLI / mix-task argument handling where invalid input should halt
  with a clear message.
  """
  @spec from_name!(String.t()) :: module
  def from_name!(name) when is_binary(name), do: env_to_module(name)

  # ─── priority-chain helpers ─────────────────────────────────────────────

  defp from_opts(opts, key), do: Keyword.get(opts, key)

  defp from_app_env(key) do
    case Application.get_env(:sykli, key) do
      nil -> nil
      module when is_atom(module) -> module
    end
  end

  defp from_sys_env do
    case System.get_env("SYKLI_RUNTIME") do
      nil -> nil
      "" -> nil
      name -> env_to_module(name)
    end
  end

  defp env_to_module(name) do
    case Map.get(@shorthand, name) do
      nil -> module_from_string(name)
      module -> ensure_loaded!(module, name)
    end
  end

  defp module_from_string("Elixir." <> _ = name) do
    module =
      try do
        String.to_existing_atom(name)
      rescue
        ArgumentError -> bad_env!(name)
      end

    ensure_loaded!(module, name)
  end

  defp module_from_string(name), do: bad_env!(name)

  defp bad_env!(name) do
    raise ArgumentError,
          "SYKLI_RUNTIME=#{name} is not recognised. " <>
            "Use one of: docker, podman, shell, fake, or Elixir.Fully.Qualified.Module"
  end

  defp ensure_loaded!(module, name) do
    if Code.ensure_loaded?(module) do
      module
    else
      raise ArgumentError,
            "SYKLI_RUNTIME=#{name} resolves to #{inspect(module)}, which is not loaded."
    end
  end

  # ─── auto-detect ────────────────────────────────────────────────────────

  defp auto_detect do
    Enum.find([Sykli.Runtime.Docker, Sykli.Runtime.Podman], fn module ->
      Code.ensure_loaded?(module) and probe(module)
    end)
  end

  defp probe(module) do
    cache = :persistent_term.get({__MODULE__, :probe_cache}, %{})

    case Map.fetch(cache, module) do
      {:ok, value} ->
        value

      :error ->
        value = run_probe(module)
        :persistent_term.put({__MODULE__, :probe_cache}, Map.put(cache, module, value))
        value
    end
  end

  defp run_probe(module) do
    probe_fn = Application.get_env(:sykli, :runtime_probe, &default_probe/1)
    probe_fn.(module) == true
  end

  defp default_probe(module) do
    match?({:ok, _}, module.available?())
  end

  defp fallback_to_shell do
    warn_once()
    Sykli.Runtime.Shell
  end

  defp warn_once do
    if :persistent_term.get({__MODULE__, :fallback_warned}, false) do
      :ok
    else
      Logger.warning("No container runtime detected; falling back to Sykli.Runtime.Shell.")
      :persistent_term.put({__MODULE__, :fallback_warned}, true)
    end
  end
end
