defmodule Sykli.Events.Event do
  @moduledoc """
  Event struct for SYKLI execution events.

  Designed for compatibility with AHTI's TapioEvent schema. Each event contains:

  - `id`: ULID for time-sorting and causality tracking
  - `timestamp`: Wall clock time when event occurred
  - `type`: Event classification (maps to AHTI EventType)
  - `run_id`: SYKLI run identifier
  - `data`: Event-specific payload

  ## AHTI Compatibility

  When exported to AHTI, SYKLI events map to TapioEvent as follows:

  | SYKLI Event     | AHTI Type    | AHTI Subtype        |
  |-----------------|--------------|---------------------|
  | :run_started    | deployment   | ci_run_started      |
  | :run_completed  | deployment   | ci_run_completed    |
  | :task_started   | deployment   | ci_task_started     |
  | :task_completed | deployment   | ci_task_completed   |
  | :task_output    | deployment   | ci_task_output      |

  ## Example

      event = Sykli.Events.Event.new(:task_completed, "run-123", %{
        task_name: "test",
        outcome: :success
      })

      # Export to AHTI format
      ahti_event = Sykli.Events.Event.to_ahti(event, "prod-cluster")
  """

  @type outcome :: :success | :failure | :timeout | :unknown
  @type severity :: :info | :warning | :error | :critical

  @type event_data ::
          Sykli.Events.RunStarted.t()
          | Sykli.Events.RunCompleted.t()
          | Sykli.Events.TaskStarted.t()
          | Sykli.Events.TaskCompleted.t()
          | Sykli.Events.TaskOutput.t()
          | map()

  @type t :: %__MODULE__{
          id: String.t(),
          timestamp: DateTime.t(),
          type: atom(),
          run_id: String.t(),
          node: atom() | nil,
          data: event_data(),
          trace_id: String.t() | nil,
          span_id: String.t() | nil,
          parent_span_id: String.t() | nil,
          duration_us: non_neg_integer() | nil
        }

  @derive Jason.Encoder
  defstruct [
    :id,
    :timestamp,
    :type,
    :run_id,
    :node,
    :data,
    :trace_id,
    :span_id,
    :parent_span_id,
    :duration_us
  ]

  @doc """
  Creates a new event with a ULID and current timestamp.
  """
  def new(type, run_id, data, opts \\ []) do
    %__MODULE__{
      id: Sykli.ULID.generate(),
      timestamp: DateTime.utc_now(),
      type: type,
      run_id: run_id,
      node: node(),
      data: data,
      trace_id: opts[:trace_id],
      span_id: opts[:span_id],
      parent_span_id: opts[:parent_span_id],
      duration_us: opts[:duration_us]
    }
  end

  @doc """
  Creates an event with a specific timestamp (for replaying/migration).
  """
  def new_with_timestamp(type, run_id, timestamp, data, opts \\ []) do
    %__MODULE__{
      id: Sykli.ULID.generate_with_timestamp(timestamp),
      timestamp: timestamp,
      type: type,
      run_id: run_id,
      node: opts[:node] || node(),
      data: data,
      trace_id: opts[:trace_id],
      span_id: opts[:span_id],
      parent_span_id: opts[:parent_span_id],
      duration_us: opts[:duration_us]
    }
  end

  @doc """
  Converts a SYKLI event to AHTI TapioEvent format.

  The `cluster` parameter is required by AHTI for multi-cluster correlation.

  ## Options

    * `:namespace` - Kubernetes namespace (optional)
    * `:labels` - Additional labels map (optional)
    * `:source` - Event source identifier (default: "sykli")

  ## Example

      ahti_event = Event.to_ahti(event, "prod-us-east-1", namespace: "ci-runners")
  """
  def to_ahti(%__MODULE__{} = event, cluster, opts \\ []) do
    %{
      id: event.id,
      timestamp: DateTime.to_iso8601(event.timestamp),
      type: ahti_event_type(event.type),
      subtype: ahti_subtype(event.type),
      severity: ahti_severity(event),
      outcome: ahti_outcome(event),
      cluster: cluster,
      namespace: opts[:namespace],
      source: opts[:source] || "sykli",
      trace_id: event.trace_id,
      span_id: event.span_id,
      parent_span_id: event.parent_span_id,
      duration: event.duration_us,
      entities: build_entities(event, cluster),
      relationships: [],
      labels:
        Map.merge(opts[:labels] || %{}, %{
          "sykli.run_id" => event.run_id,
          "sykli.node" => to_string(event.node)
        })
    }
    |> Map.merge(event_specific_data(event))
    |> remove_nil_values()
  end

  @doc """
  Encodes an event to JSON.
  """
  def to_json(%__MODULE__{} = event) do
    Jason.encode!(event)
  end

  @doc """
  Encodes an event in AHTI format to JSON.
  """
  def to_ahti_json(%__MODULE__{} = event, cluster, opts \\ []) do
    event
    |> to_ahti(cluster, opts)
    |> Jason.encode!()
  end

  # Map SYKLI event types to AHTI EventType
  defp ahti_event_type(:run_started), do: "deployment"
  defp ahti_event_type(:run_completed), do: "deployment"
  defp ahti_event_type(:task_started), do: "deployment"
  defp ahti_event_type(:task_completed), do: "deployment"
  defp ahti_event_type(:task_output), do: "deployment"
  defp ahti_event_type(_), do: "deployment"

  # Map to AHTI subtype
  defp ahti_subtype(:run_started), do: "ci_run_started"
  defp ahti_subtype(:run_completed), do: "ci_run_completed"
  defp ahti_subtype(:task_started), do: "ci_task_started"
  defp ahti_subtype(:task_completed), do: "ci_task_completed"
  defp ahti_subtype(:task_output), do: "ci_task_output"
  defp ahti_subtype(type), do: "ci_#{type}"

  # Determine severity from event type and outcome - handle both struct and map
  defp ahti_severity(%{type: :task_completed, data: data}) do
    outcome = if is_struct(data), do: data.outcome, else: data[:outcome]
    if outcome == :failure, do: "error", else: "info"
  end

  defp ahti_severity(%{type: :run_completed, data: data}) do
    outcome = if is_struct(data), do: data.outcome, else: data[:outcome]
    if outcome == :failure, do: "error", else: "info"
  end

  defp ahti_severity(%{type: :task_output}), do: "info"
  defp ahti_severity(_), do: "info"

  # Determine outcome - handle both struct and map data formats
  defp ahti_outcome(%{data: data}) when is_struct(data) do
    case Map.get(data, :outcome) do
      outcome when outcome in [:success, :failure, :timeout] -> to_string(outcome)
      _ -> "unknown"
    end
  end

  defp ahti_outcome(%{data: %{outcome: outcome}})
       when outcome in [:success, :failure, :timeout] do
    to_string(outcome)
  end

  defp ahti_outcome(%{type: :task_started}), do: "unknown"
  defp ahti_outcome(%{type: :run_started}), do: "unknown"
  defp ahti_outcome(_), do: "success"

  # Build AHTI entities from event - handle both struct and map data
  defp build_entities(%{type: :run_started} = event, cluster) do
    data = event.data
    project_path = get_data_field(data, :project_path) || ""
    task_count = get_data_field(data, :task_count) || 0

    [
      %{
        type: "deployment",
        id: "sykli-run-#{event.run_id}",
        name: "SYKLI Run #{event.run_id}",
        cluster_id: cluster,
        state: "active",
        attributes: %{
          "project_path" => project_path,
          "task_count" => to_string(task_count)
        }
      }
    ]
  end

  defp build_entities(%{type: type} = event, cluster)
       when type in [:task_started, :task_completed, :task_output] do
    task_name = get_data_field(event.data, :task_name) || ""

    [
      %{
        type: "container",
        id: "sykli-task-#{event.run_id}-#{task_name}",
        name: task_name,
        cluster_id: cluster,
        state: if(type == :task_completed, do: "deleted", else: "active"),
        attributes: %{
          "run_id" => event.run_id,
          "task_name" => task_name
        }
      }
    ]
  end

  defp build_entities(%{type: :run_completed} = event, cluster) do
    [
      %{
        type: "deployment",
        id: "sykli-run-#{event.run_id}",
        name: "SYKLI Run #{event.run_id}",
        cluster_id: cluster,
        state: "deleted",
        delete_reason: if(event.data[:outcome] == :success, do: "completed", else: "failed")
      }
    ]
  end

  defp build_entities(_event, _cluster), do: []

  # Add event-specific data structures (matching AHTI's typed data fields)
  defp event_specific_data(%{type: :task_completed, data: data}) do
    task_name = get_data_field(data, :task_name) || ""
    outcome = get_data_field(data, :outcome)

    %{
      process_data: %{
        command: task_name,
        exit_code: if(outcome == :success, do: 0, else: 1)
      }
    }
  end

  defp event_specific_data(%{type: :task_output, data: data}) do
    task_name = get_data_field(data, :task_name) || ""
    output = get_data_field(data, :output) || ""

    %{
      process_data: %{
        command: task_name,
        args: String.slice(output, 0, 1000)
      }
    }
  end

  defp event_specific_data(_), do: %{}

  # Helper to access data fields from both structs and maps
  defp get_data_field(data, field) when is_struct(data), do: Map.get(data, field)
  defp get_data_field(data, field) when is_map(data), do: data[field]
  defp get_data_field(_, _), do: nil

  defp remove_nil_values(map) when is_map(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.map(fn {k, v} -> {k, remove_nil_values(v)} end)
    |> Map.new()
  end

  defp remove_nil_values(value), do: value
end
