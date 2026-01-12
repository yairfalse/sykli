defmodule Sykli.K8s do
  @moduledoc """
  Kubernetes-specific configuration for tasks.

  This is a minimal API covering 95% of CI use cases.
  For advanced options (tolerations, affinity, security contexts),
  use `raw/2` to pass raw JSON.

  ## Example

      alias Sykli.K8s

      task "build" do
        run "cargo build"
        k8s K8s.options()
             |> K8s.memory("4Gi")
             |> K8s.cpu("2")
      end

      # For GPU tasks
      task "train" do
        run "python train.py"
        k8s K8s.options()
             |> K8s.memory("32Gi")
             |> K8s.gpu(1)
      end

      # For advanced options (tolerations, affinity, etc.)
      task "gpu-train" do
        run "python train.py"
        k8s K8s.options()
             |> K8s.memory("32Gi")
             |> K8s.gpu(1)
             |> K8s.raw(~s({"nodeSelector": {"gpu": "true"}}))
      end

  ## Validation

  Memory and CPU options are validated when the pipeline is emitted:

      # This will fail with a helpful message:
      k8s K8s.options() |> K8s.memory("4gb")
      # => k8s.memory: invalid format '4gb' (did you mean 'Gi'?)

  """

  require Logger

  # =============================================================================
  # OPTIONS STRUCT (Minimal API)
  # =============================================================================

  defstruct memory: nil,
            cpu: nil,
            gpu: nil,
            raw: nil

  @type t :: %__MODULE__{
          memory: String.t() | nil,
          cpu: String.t() | nil,
          gpu: non_neg_integer() | nil,
          raw: String.t() | nil
        }

  # =============================================================================
  # VALIDATION ERROR
  # =============================================================================

  defmodule ValidationError do
    @moduledoc "K8s validation error with field, value, and message."
    defexception [:field, :value, :message]

    @impl true
    def message(%{field: field, value: value, message: msg}) do
      "k8s.#{field}: #{msg} (got #{inspect(value)})"
    end
  end

  # =============================================================================
  # BUILDER API
  # =============================================================================

  @doc "Creates a new K8s options struct."
  @spec options() :: t()
  def options, do: %__MODULE__{}

  @doc """
  Sets memory resource (both request and limit).

  Use K8s binary units: Ki, Mi, Gi, Ti.

  ## Examples

      K8s.options() |> K8s.memory("4Gi")
      K8s.options() |> K8s.memory("512Mi")
  """
  @spec memory(t(), String.t()) :: t()
  def memory(opts, value) when is_binary(value) do
    %{opts | memory: value}
  end

  @doc """
  Sets CPU resource (both request and limit).

  Use cores (e.g., "2") or millicores (e.g., "500m").

  ## Examples

      K8s.options() |> K8s.cpu("2")
      K8s.options() |> K8s.cpu("500m")
  """
  @spec cpu(t(), String.t()) :: t()
  def cpu(opts, value) when is_binary(value) do
    %{opts | cpu: value}
  end

  @doc "Requests NVIDIA GPUs."
  @spec gpu(t(), non_neg_integer()) :: t()
  def gpu(opts, count) when is_integer(count) and count >= 0 do
    %{opts | gpu: count}
  end

  @doc """
  Adds raw Kubernetes configuration as JSON.

  Use this for advanced options not covered by the minimal API
  (tolerations, affinity, security contexts, etc.).
  The JSON is passed directly to the executor.

  ## Examples

      # GPU node with toleration
      K8s.options()
      |> K8s.memory("32Gi")
      |> K8s.gpu(1)
      |> K8s.raw(~s({"nodeSelector": {"gpu": "true"}, "tolerations": [{"key": "gpu", "effect": "NoSchedule"}]}))
  """
  @spec raw(t(), String.t()) :: t()
  def raw(opts, json_config) when is_binary(json_config) do
    %{opts | raw: json_config}
  end

  # =============================================================================
  # VALIDATION
  # =============================================================================

  # Memory pattern: Ki, Mi, Gi, Ti, Pi, Ei (binary) or k, M, G, T, P, E (decimal)
  @memory_pattern ~r/^[0-9]+(\.[0-9]+)?(Ki|Mi|Gi|Ti|Pi|Ei|k|M|G|T|P|E)?$/

  # CPU pattern: whole numbers, decimals, or millicores
  @cpu_pattern ~r/^[0-9]+(\.[0-9]+)?m?$/

  @doc """
  Validates K8s options. Returns {:ok, opts} or {:error, errors}.

  ## Examples

      iex> K8s.validate(K8s.options() |> K8s.memory("4Gi"))
      {:ok, %Sykli.K8s{...}}

      iex> K8s.validate(K8s.options() |> K8s.memory("4gb"))
      {:error, [%Sykli.K8s.ValidationError{field: "memory", ...}]}
  """
  @spec validate(t()) :: {:ok, t()} | {:error, [ValidationError.t()]}
  def validate(opts) do
    errors = List.flatten([
      validate_memory(opts.memory),
      validate_cpu(opts.cpu)
    ])

    case errors do
      [] -> {:ok, opts}
      errors -> {:error, errors}
    end
  end

  @doc """
  Validates K8s options. Raises on errors.
  """
  @spec validate!(t()) :: t()
  def validate!(opts) do
    case validate(opts) do
      {:ok, opts} -> opts
      {:error, [first | _rest]} -> raise first
    end
  end

  defp validate_memory(nil), do: []
  defp validate_memory(value) do
    if Regex.match?(@memory_pattern, value) do
      []
    else
      # Provide helpful suggestions for common mistakes
      lower = String.downcase(value)
      suggestion = cond do
        String.ends_with?(lower, "gb") -> " (did you mean 'Gi'?)"
        String.ends_with?(lower, "mb") -> " (did you mean 'Mi'?)"
        String.ends_with?(lower, "kb") -> " (did you mean 'Ki'?)"
        true -> ""
      end

      [%ValidationError{
        field: "memory",
        value: value,
        message: "invalid memory format, use Ki/Mi/Gi/Ti (e.g., '512Mi', '4Gi')#{suggestion}"
      }]
    end
  end

  defp validate_cpu(nil), do: []
  defp validate_cpu(value) do
    if Regex.match?(@cpu_pattern, value) do
      []
    else
      [%ValidationError{
        field: "cpu",
        value: value,
        message: "invalid CPU format, use cores or millicores (e.g., '500m', '0.5', '2')"
      }]
    end
  end

  # =============================================================================
  # JSON SERIALIZATION
  # =============================================================================

  @doc "Converts K8s options to a JSON-serializable map."
  @spec to_json(t()) :: map() | nil
  def to_json(%__MODULE__{} = opts) do
    base = %{}

    base
    |> maybe_put(:memory, opts.memory)
    |> maybe_put(:cpu, opts.cpu)
    |> maybe_put(:gpu, opts.gpu)
    |> maybe_put(:raw, opts.raw)
    |> non_empty_map()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp non_empty_map(map) when map_size(map) == 0, do: nil
  defp non_empty_map(map), do: map
end
