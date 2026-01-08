defmodule Sykli.NodeProfile do
  @moduledoc """
  Node labels and capabilities for task placement.

  Labels are strings that describe what a node can do. Some are auto-detected
  (OS, architecture), others are user-defined via environment variables.

  ## Zero Config

  Base labels are detected automatically:

      iex> Sykli.NodeProfile.labels()
      ["darwin", "arm64"]

  ## Adding Labels

  Via environment variable (CI-friendly):

      SYKLI_LABELS=docker,gpu,builder

  Via CLI flag:

      sykli daemon start --labels=docker,gpu

  ## Namespaced Labels

  Use colons for organization:

      SYKLI_LABELS=team:ml,region:us-east,env:prod

  ## Usage in Tasks

  Tasks can require labels for placement:

      p.task("train")
        .requires("gpu")
        .requires("team:ml")

  Labels are an optimization - without them, the mesh tries all nodes
  and learns from failures.
  """

  @doc """
  All labels for this node (base + user-defined).

  Returns a list of strings.

  ## Examples

      iex> Sykli.NodeProfile.labels()
      ["darwin", "arm64", "docker", "gpu"]
  """
  @spec labels() :: [String.t()]
  def labels do
    base_labels() ++ user_labels()
  end

  @doc """
  User-defined labels from SYKLI_LABELS environment variable.

  ## Examples

      iex> System.put_env("SYKLI_LABELS", "docker,gpu")
      iex> Sykli.NodeProfile.user_labels()
      ["docker", "gpu"]
  """
  @spec user_labels() :: [String.t()]
  def user_labels do
    case System.get_env("SYKLI_LABELS") do
      nil -> []
      "" -> []
      labels -> parse_labels(labels)
    end
  end

  @doc """
  Check if this node has a specific label.

  ## Examples

      iex> Sykli.NodeProfile.has_label?("docker")
      true
  """
  @spec has_label?(String.t()) :: boolean()
  def has_label?(label) when is_binary(label) do
    label in labels()
  end

  @doc """
  Full capabilities map for this node.

  Includes labels, CPU count, and memory. Used for RPC
  when remote nodes query capabilities.

  ## Examples

      iex> Sykli.NodeProfile.capabilities()
      %{labels: ["darwin", "arm64"], cpus: 8, memory_mb: 16384}
  """
  @spec capabilities() :: map()
  def capabilities do
    %{
      labels: labels(),
      cpus: System.schedulers_online(),
      memory_mb: total_memory_mb()
    }
  end

  # ---------------------------------------------------------------------------
  # PRIVATE - Base Labels (Auto-detected)
  # ---------------------------------------------------------------------------

  defp base_labels do
    [os_label(), arch_label()]
    |> Enum.reject(&is_nil/1)
  end

  defp os_label do
    case :os.type() do
      {:unix, :darwin} -> "darwin"
      {:unix, :linux} -> "linux"
      {:unix, _other} -> "unix"
      {:win32, _} -> "windows"
      _ -> nil
    end
  end

  defp arch_label do
    arch = :erlang.system_info(:system_architecture) |> to_string()

    cond do
      String.contains?(arch, "aarch64") -> "arm64"
      String.contains?(arch, "arm64") -> "arm64"
      String.contains?(arch, "x86_64") -> "amd64"
      String.contains?(arch, "amd64") -> "amd64"
      true -> arch
    end
  end

  # ---------------------------------------------------------------------------
  # PRIVATE - Parsing
  # ---------------------------------------------------------------------------

  defp parse_labels(labels_string) do
    labels_string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # ---------------------------------------------------------------------------
  # PRIVATE - System Info
  # ---------------------------------------------------------------------------

  defp total_memory_mb do
    case :os.type() do
      {:unix, :darwin} ->
        {output, 0} = System.cmd("sysctl", ["-n", "hw.memsize"])
        bytes = output |> String.trim() |> String.to_integer()
        div(bytes, 1024 * 1024)

      {:unix, _} ->
        case File.read("/proc/meminfo") do
          {:ok, content} ->
            case Regex.run(~r/MemTotal:\s+(\d+)\s+kB/, content) do
              [_, kb] -> div(String.to_integer(kb), 1024)
              _ -> 0
            end

          _ ->
            0
        end

      _ ->
        0
    end
  rescue
    _ -> 0
  end
end
