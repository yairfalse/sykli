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
        mandate_changes(name, before, after_) ++
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

  defp mandate_changes(name, before, after_) do
    case {before["mandate"], after_["mandate"]} do
      {same, same} ->
        []

      {nil, %{}} ->
        [change(:mandate_added, name, "mandate", "mandate added", :strengthening)]

      {%{}, nil} ->
        [change(:mandate_removed, name, "mandate", "mandate removed", :weakening)]

      {from, to} ->
        scope_changes(name, from["scope"], to["scope"]) ++
          budget_changes(name, from["budget"], to["budget"]) ++
          network_changes(name, from["capabilities"], to["capabilities"])
    end
  end

  defp scope_changes(name, before, after_) do
    before_set = MapSet.new(before || [])
    after_set = MapSet.new(after_ || [])

    cond do
      MapSet.equal?(before_set, after_set) ->
        []

      MapSet.subset?(after_set, before_set) ->
        [change(:scope_narrowed, name, "mandate.scope", "mandate scope narrowed", :strengthening)]

      true ->
        # New patterns grant territory the old scope did not; without glob
        # semantics we cannot prove containment, so any addition is widening.
        [change(:scope_widened, name, "mandate.scope", "mandate scope widened", :weakening)]
    end
  end

  defp budget_changes(name, before, after_) do
    Enum.flat_map(["diff_lines", "wall_clock_ms"], fn key ->
      budget_key_change(name, key, (before || %{})[key], (after_ || %{})[key])
    end)
  end

  defp budget_key_change(_name, _key, value, value), do: []

  defp budget_key_change(name, key, nil, _added) do
    [change(:budget_added, name, "mandate.budget.#{key}", "#{key} budget added", :strengthening)]
  end

  defp budget_key_change(name, key, _removed, nil) do
    [change(:budget_removed, name, "mandate.budget.#{key}", "#{key} budget removed", :weakening)]
  end

  defp budget_key_change(name, key, before, after_) when after_ > before do
    [change(:budget_raised, name, "mandate.budget.#{key}", "#{key} budget raised", :weakening)]
  end

  defp budget_key_change(name, key, _before, _after) do
    [
      change(
        :budget_lowered,
        name,
        "mandate.budget.#{key}",
        "#{key} budget lowered",
        :strengthening
      )
    ]
  end

  # Absent network capability means unconstrained (allowed), so only
  # transitions across `network: false` change enforcement.
  defp network_changes(name, before, after_) do
    before_denied = (before || %{})["network"] == false
    after_denied = (after_ || %{})["network"] == false

    cond do
      before_denied and not after_denied ->
        [
          change(
            :network_allowed,
            name,
            "mandate.capabilities.network",
            "network access allowed",
            :weakening
          )
        ]

      after_denied and not before_denied ->
        [
          change(
            :network_denied,
            name,
            "mandate.capabilities.network",
            "network access denied",
            :strengthening
          )
        ]

      true ->
        []
    end
  end

  defp neutral_changes(name, before, after_) do
    [
      neutral_if_changed(name, "command", before["command"], after_["command"]),
      neutral_if_changed(name, "depends_on", before["depends_on"], after_["depends_on"]),
      neutral_if_changed(name, "env", before["env"], after_["env"]),
      neutral_if_changed(name, "actor", before["actor"], after_["actor"])
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
