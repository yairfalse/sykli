defmodule Sykli.GitHub.CheckRunFormatter do
  @moduledoc "Formats task results for GitHub check runs."

  alias Sykli.Executor.TaskResult

  @max_lines 50

  @spec conclusion(TaskResult.t()) :: String.t()
  def conclusion(%TaskResult{status: :passed}), do: "success"
  def conclusion(%TaskResult{status: :failed}), do: "failure"
  def conclusion(%TaskResult{status: :errored}), do: "failure"
  def conclusion(%TaskResult{status: :cached}), do: "success"
  def conclusion(%TaskResult{status: :skipped}), do: "skipped"
  def conclusion(%TaskResult{status: :blocked}), do: "cancelled"

  @spec format(TaskResult.t()) :: %{title: String.t(), summary: String.t()}
  def format(%TaskResult{} = result) do
    %{
      title: title(result),
      summary: summary(result)
    }
  end

  defp title(%TaskResult{name: name, status: :cached}), do: "#{name}: cached (cache hit)"
  defp title(%TaskResult{name: name, status: status}), do: "#{name}: #{status}"

  defp summary(%TaskResult{status: :errored} = result) do
    [
      "Infrastructure failure while running `#{result.name}`.",
      "",
      output_block(result)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp summary(%TaskResult{} = result) do
    [
      "Task `#{result.name}` finished with status `#{result.status}`.",
      output_block(result)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp output_block(%TaskResult{} = result) do
    output =
      [result.output, error_output(result.error)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")
      |> last_lines(@max_lines)

    if output == "" do
      ""
    else
      "```text\n#{output}\n```"
    end
  end

  defp error_output(%Sykli.Error{output: output}) when is_binary(output), do: output
  defp error_output(%Sykli.Error{message: message}) when is_binary(message), do: message
  defp error_output(nil), do: nil
  defp error_output(error), do: inspect(error)

  defp last_lines("", _limit), do: ""

  defp last_lines(text, limit) do
    text
    |> String.split("\n")
    |> Enum.take(-limit)
    |> Enum.join("\n")
  end
end
