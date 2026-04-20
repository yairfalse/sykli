defmodule Sykli.RuntimeIsolationTest do
  @moduledoc """
  Regression guard: no module outside `core/lib/sykli/runtime/` may name a
  specific runtime implementation. Implementations must be selected through
  `Sykli.Runtime.Resolver` (once it exists — RC.3).

  If this test fails, you probably hardcoded `Sykli.Runtime.Docker` (or a
  sibling). Route the selection through `Sykli.Runtime.Resolver` instead.

  Tagged `:regression_guard` and excluded by default until RC.4c completes —
  at which point the pre-refactor hardcoding in `target/local.ex` has been
  removed and this test turns green. Opt in early with:

      mix test --include regression_guard

  The moment this test can be un-tagged and still pass is the objective
  signal that the runtime decoupling is complete.
  """

  use ExUnit.Case, async: true

  @moduletag :regression_guard

  @runtime_modules ~w(Docker Podman Shell Fake Containerd)
  @repo_root Path.expand("../../..", __DIR__)
  @runtime_dir Path.join(@repo_root, "core/lib/sykli/runtime")

  test "no module outside core/lib/sykli/runtime/ names a runtime implementation" do
    offenders =
      Path.join(@repo_root, "core/lib/sykli/**/*.ex")
      |> Path.wildcard()
      |> Enum.reject(&inside_runtime_dir?/1)
      |> Enum.flat_map(&scan_file/1)

    assert offenders == [],
           "Runtime modules named outside core/lib/sykli/runtime/:\n" <>
             Enum.map_join(offenders, "\n", fn {path, line, snippet} ->
               rel = Path.relative_to(path, @repo_root)
               "  #{rel}:#{line}  #{snippet}"
             end)
  end

  defp inside_runtime_dir?(path) do
    String.starts_with?(Path.expand(path), @runtime_dir <> "/")
  end

  defp scan_file(path) do
    pattern = ~r/Sykli\.Runtime\.(#{Enum.join(@runtime_modules, "|")})\b/

    path
    |> File.stream!([], :line)
    |> Stream.with_index(1)
    |> Enum.map_reduce(false, fn {line, lineno}, in_docstring? ->
      in_next = toggle_docstring(line, in_docstring?)
      skip? = in_docstring? or in_next or comment_only?(line)

      match =
        case Regex.run(pattern, line) do
          nil -> nil
          [_ | _] when skip? -> nil
          [_ | _] -> {path, lineno, line |> String.trim() |> String.slice(0, 120)}
        end

      {match, in_next}
    end)
    |> elem(0)
    |> Enum.reject(&is_nil/1)
  end

  defp toggle_docstring(line, in_docstring?) do
    # Count unmatched `"""` markers on the line (ignoring string interpolation).
    triple_count = line |> String.split(~s(""")) |> length() |> Kernel.-(1)
    if rem(triple_count, 2) == 1, do: not in_docstring?, else: in_docstring?
  end

  defp comment_only?(line) do
    String.match?(line, ~r/^\s*#/)
  end
end
