defmodule Sykli.CLI.FixRendererTest do
  use ExUnit.Case, async: true

  alias Sykli.CLI.FixRenderer

  describe "render/1" do
    test "nothing_to_fix returns success message" do
      output =
        %{status: :nothing_to_fix}
        |> FixRenderer.render()
        |> IO.iodata_to_binary()

      assert output =~ "●  Nothing to fix. Last run passed."
    end

    test "failure_found renders header, task details, and proposed fix" do
      output =
        failure_result()
        |> FixRenderer.render()
        |> IO.iodata_to_binary()

      assert output =~ "✕  1 of 3 tasks failed · abc1234 · main"
      assert output =~ "✕  test:auth"
      assert output =~ "$ npm test -- --filter auth"
      assert output =~ "exit code 1"
      assert output =~ "src/auth.ts:42"
      assert output =~ "Expected token"
      assert output =~ "because  src/auth.ts changed"
      assert output =~ "fix      check token format"
      assert output =~ "94% pass rate"
    end

    test "failure_found renders diff stat" do
      output =
        failure_result(%{
          diff_since_last_good: %{
            "ref" => "abc1234",
            "stat" => "src/auth.ts | 12 +++---"
          }
        })
        |> FixRenderer.render()
        |> IO.iodata_to_binary()

      assert output =~ "Changes since abc1234"
      assert output =~ "src/auth.ts | 12 +++---"
    end
  end

  defp failure_result(overrides \\ %{}) do
    Map.merge(
      %{
        status: :failure_found,
        summary: %{
          "failed_count" => 1,
          "total_count" => 3,
          "git_ref" => "abc1234def",
          "git_branch" => "main"
        },
        tasks: [
          %{
            "name" => "test:auth",
            "command" => "npm test -- --filter auth",
            "exit_code" => 1,
            "locations" => [
              %{
                "file" => "src/auth.ts",
                "line" => 42,
                "message" => "Expected token",
                "source_lines" => ["41 | const token = nil", ">> 42 | parse(token)"]
              }
            ],
            "possible_causes" => ["src/auth.ts changed"],
            "suggested_fix" => "check token format",
            "history" => %{"pass_rate" => 0.94, "streak" => 0, "flaky" => false}
          }
        ],
        diff_since_last_good: nil
      },
      overrides
    )
  end
end
