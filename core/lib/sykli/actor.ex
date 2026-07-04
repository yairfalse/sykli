defmodule Sykli.Actor do
  @moduledoc """
  Validation helpers for v5 task `actor` declarations.
  """

  @kinds ~w(human agent service)

  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @spec valid_kind?(term()) :: boolean()
  def valid_kind?(kind), do: kind in @kinds

  @spec parse(term(), :task | :review, String.t(), String.t() | nil) ::
          {:ok, map() | nil} | {:error, term()}
  def parse(nil, _kind, _version, _task_name), do: {:ok, nil}

  def parse(actor, kind, version, task_name) do
    case validate(actor, kind, version, task_name) do
      :ok -> {:ok, normalize(actor)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec validate(term(), :task | :review, String.t(), String.t() | nil) ::
          :ok | {:error, term()}
  def validate(nil, _kind, _version, _task_name), do: :ok

  def validate(_actor, :review, _version, task_name) do
    {:error, {:actor_on_review, task_name}}
  end

  def validate(_actor, _kind, version, task_name) when version != "5" do
    {:error, {:actor_requires_version_5, task_name, version}}
  end

  def validate(%{"kind" => kind} = actor, _kind, "5", task_name) do
    with :ok <- validate_kind(kind, task_name),
         :ok <- validate_id(actor, task_name) do
      validate_no_extra_keys(actor, ["kind", "id"], task_name)
    end
  end

  def validate(%{} = _actor, _kind, "5", task_name) do
    {:error, {:invalid_actor, task_name, "requires kind"}}
  end

  def validate(_actor, _kind, "5", task_name) do
    {:error, {:invalid_actor, task_name, "must be an object"}}
  end

  @spec format_error(term()) :: String.t()
  def format_error(reason), do: "Error: #{message(reason)}"

  @spec to_error_map(term()) :: map()
  def to_error_map(reason) do
    %{
      type: error_type(reason),
      task: error_task(reason),
      message: message(reason)
    }
  end

  @spec message(term()) :: String.t()
  def message({:actor_on_review, task_name}) do
    "Review node '#{task_name}' cannot declare actor"
  end

  def message({:actor_requires_version_5, task_name, version}) do
    "Task '#{task_name}' declares actor but pipeline version is #{inspect(version)}, not \"5\""
  end

  def message({:invalid_actor, task_name, reason}) do
    "Task '#{task_name}' declares invalid actor: #{reason}"
  end

  def message({:unknown_actor_kind, task_name, kind}) do
    "Task '#{task_name}' declares unknown actor kind #{inspect(kind)}"
  end

  defp validate_kind(kind, _task_name) when kind in @kinds, do: :ok
  defp validate_kind(kind, task_name), do: {:error, {:unknown_actor_kind, task_name, kind}}

  defp validate_id(%{"id" => id}, task_name) when not is_binary(id) or id == "" do
    {:error, {:invalid_actor, task_name, "id must be a non-empty string"}}
  end

  defp validate_id(_actor, _task_name), do: :ok

  defp validate_no_extra_keys(actor, allowed_keys, task_name) do
    extra_keys = Map.keys(actor) -- allowed_keys

    if extra_keys == [] do
      :ok
    else
      {:error, {:invalid_actor, task_name, "unknown keys: #{Enum.join(extra_keys, ", ")}"}}
    end
  end

  defp normalize(actor), do: Map.take(actor, ["kind", "id"])

  defp error_type({type, _task_name}) when is_atom(type), do: type
  defp error_type({type, _task_name, _detail}) when is_atom(type), do: type

  defp error_task({_type, task_name}), do: task_name
  defp error_task({_type, task_name, _detail}), do: task_name
end
