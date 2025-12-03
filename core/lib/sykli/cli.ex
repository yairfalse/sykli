defmodule Sykli.CLI do
  @moduledoc """
  CLI entry point for escript.
  """

  def main(args \\ []) do
    path = List.first(args) || "."

    case Sykli.run(path) do
      {:ok, results} ->
        IO.puts("\n#{IO.ANSI.green()}All tasks passed#{IO.ANSI.reset()}")
        Enum.each(results, fn {name, _} ->
          IO.puts("  ✓ #{name}")
        end)

      {:error, :no_sdk_file} ->
        IO.puts("#{IO.ANSI.red()}No sykli.go, sykli.rs, or sykli.ts found#{IO.ANSI.reset()}")
        System.halt(1)

      {:error, results} when is_list(results) ->
        IO.puts("\n#{IO.ANSI.red()}Build failed#{IO.ANSI.reset()}")
        System.halt(1)

      {:error, reason} ->
        IO.puts("#{IO.ANSI.red()}Error: #{inspect(reason)}#{IO.ANSI.reset()}")
        System.halt(1)
    end
  end
end
