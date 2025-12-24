defmodule Sykli.ConditionEvaluator do
  @moduledoc """
  Safe condition expression evaluator.

  Only allows:
  - Variable references: branch, tag, event, pr_number, ci
  - String literals: "main", "release"
  - Boolean literals: true, false
  - Comparison: ==, !=
  - Logical: and, or, not
  """

  @allowed_vars [:branch, :tag, :event, :pr_number, :ci]

  @doc """
  Evaluates a condition string against a context map.
  Returns true/false or {:error, reason} for invalid conditions.
  """
  def evaluate(condition, context) when is_binary(condition) do
    case Code.string_to_quoted(condition) do
      {:ok, ast} ->
        case validate_ast(ast) do
          :ok -> {:ok, eval_ast(ast, context)}
          {:error, reason} -> {:error, reason}
        end

      {:error, {_line, message, _token}} ->
        {:error, "parse error: #{message}"}
    end
  end

  # ----- AST VALIDATION -----

  # Allow variable references (only whitelisted)
  defp validate_ast({var, _meta, nil}) when var in @allowed_vars, do: :ok

  defp validate_ast({var, _meta, nil}) when is_atom(var) do
    {:error, "unknown variable: #{var}. Allowed: #{Enum.join(@allowed_vars, ", ")}"}
  end

  # Allow string literals
  defp validate_ast(str) when is_binary(str), do: :ok

  # Allow boolean literals
  defp validate_ast(bool) when is_boolean(bool), do: :ok

  # Allow nil
  defp validate_ast(nil), do: :ok

  # Allow comparison operators
  defp validate_ast({op, _meta, [left, right]}) when op in [:==, :!=] do
    with :ok <- validate_ast(left),
         :ok <- validate_ast(right) do
      :ok
    end
  end

  # Allow logical operators
  defp validate_ast({op, _meta, [left, right]}) when op in [:and, :or] do
    with :ok <- validate_ast(left),
         :ok <- validate_ast(right) do
      :ok
    end
  end

  # Allow 'not' operator
  defp validate_ast({:not, _meta, [expr]}) do
    validate_ast(expr)
  end

  # Reject everything else
  defp validate_ast(other) do
    {:error, "unsupported expression: #{inspect(other)}"}
  end

  # ----- AST EVALUATION -----

  # Variable lookup
  defp eval_ast({var, _meta, nil}, context) when var in @allowed_vars do
    Map.get(context, var)
  end

  # Literals
  defp eval_ast(str, _context) when is_binary(str), do: str
  defp eval_ast(bool, _context) when is_boolean(bool), do: bool
  defp eval_ast(nil, _context), do: nil

  # Comparison
  defp eval_ast({:==, _meta, [left, right]}, context) do
    eval_ast(left, context) == eval_ast(right, context)
  end

  defp eval_ast({:!=, _meta, [left, right]}, context) do
    eval_ast(left, context) != eval_ast(right, context)
  end

  # Logical
  defp eval_ast({:and, _meta, [left, right]}, context) do
    eval_ast(left, context) && eval_ast(right, context)
  end

  defp eval_ast({:or, _meta, [left, right]}, context) do
    eval_ast(left, context) || eval_ast(right, context)
  end

  defp eval_ast({:not, _meta, [expr]}, context) do
    !eval_ast(expr, context)
  end
end
