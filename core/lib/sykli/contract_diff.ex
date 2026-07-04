defmodule Sykli.ContractDiff do
  @moduledoc """
  Pure contract change classifier for `sykli contract --diff`.
  """

  @criticality %{"low" => 1, "medium" => 2, "high" => 3, "critical" => 4}

  def classify(from, to) when is_map(from) and is_map(to) do
    from_tasks = tasks_by_name(from)
    to_tasks = tasks_by_name(to)

    removed_tasks(from_tasks, to_tasks) ++
      added_tasks(from_tasks, to_tasks) ++
      changed_tasks(from_tasks, to_tasks)
  end

  defp removed_tasks(from_tasks, to_tasks) do
    from_tasks
    |> Map.drop(Map.keys(to_tasks))
    |> Enum.map(fn {name, _task} ->
      change(:task_removed, name, nil, "task removed", :weakening)
    end)
  end

  defp added_tasks(from_tasks, to_tasks) do
    to_tasks
    |> Map.drop(Map.keys(from_tasks))
    |> Enum.map(fn {name, task} ->
      direction = if gate_or_review?(task), do: :strengthening, else: :neutral
      change(:task_added, name, nil, "task added", direction)
    end)
  end

  defp changed_tasks(from_tasks, to_tasks) do
    common = Enum.filter(Map.keys(from_tasks), &Map.has_key?(to_tasks, &1))

    Enum.flat_map(common, fn name ->
      before = from_tasks[name]
      after_ = to_tasks[name]

      criteria_changes(name, before, after_) ++
        evidence_changes(name, before, after_) ++
        criticality_changes(name, before, after_) ++
        condition_changes(name, before, after_) ++
        neutral_changes(name, before, after_)
    end)
  end

  defp criteria_changes(name, before, after_) do
    list_entry_changes(
      name,
      "success_criteria",
      before["success_criteria"],
      after_["success_criteria"]
    )
  end

  defp evidence_changes(name, before, after_) do
    list_entry_changes(
      name,
      "evidence_required",
      before["evidence_required"],
      after_["evidence_required"]
    )
  end

  defp list_entry_changes(name, field, before, after_) do
    before_set = MapSet.new(before || [], &canonical/1)
    after_set = MapSet.new(after_ || [], &canonical/1)

    removed =
      before_set
      |> MapSet.difference(after_set)
      |> Enum.map(fn _ ->
        change(:entry_removed, name, field, "#{field} entry removed", :weakening)
      end)

    added =
      after_set
      |> MapSet.difference(before_set)
      |> Enum.map(fn _ ->
        change(:entry_added, name, field, "#{field} entry added", :strengthening)
      end)

    removed ++ added
  end

  defp criticality_changes(name, before, after_) do
    before_rank = criticality(before)
    after_rank = criticality(after_)

    cond do
      is_nil(before_rank) or is_nil(after_rank) or before_rank == after_rank ->
        []

      after_rank < before_rank ->
        [change(:criticality_lowered, name, "criticality", "criticality lowered", :weakening)]

      true ->
        [change(:criticality_changed, name, "criticality", "criticality changed", :neutral)]
    end
  end

  defp condition_changes(name, before, after_) do
    before_condition = before["when"] || before["condition"]
    after_condition = after_["when"] || after_["condition"]

    if blank?(before_condition) and not blank?(after_condition) do
      [
        change(
          :condition_added,
          name,
          "condition",
          "condition added to unconditional task",
          :weakening
        )
      ]
    else
      []
    end
  end

  defp neutral_changes(name, before, after_) do
    [
      neutral_if_changed(name, "command", before["command"], after_["command"]),
      neutral_if_changed(name, "depends_on", before["depends_on"], after_["depends_on"]),
      neutral_if_changed(name, "env", before["env"], after_["env"])
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp neutral_if_changed(_name, _field, value, value), do: nil

  defp neutral_if_changed(name, field, _before, _after) do
    change(:field_changed, name, field, "#{field} changed", :neutral)
  end

  defp tasks_by_name(contract) do
    contract
    |> Map.get("tasks", [])
    |> Enum.filter(&is_map/1)
    |> Map.new(fn task -> {task["name"], task} end)
  end

  defp gate_or_review?(task), do: task["gate"] != nil or task["kind"] == "review"

  defp criticality(task) do
    task
    |> Map.get("criticality")
    |> then(&Map.get(@criticality, &1))
  end

  defp canonical(value), do: Jason.encode!(value)

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp change(kind, task, field, detail, direction) do
    %{kind: kind, task: task, field: field, detail: detail, direction: direction}
  end
end
