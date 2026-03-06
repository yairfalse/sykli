defmodule Sykli.Fix.OutputTest do
  use ExUnit.Case, async: true

  alias Sykli.Fix.Output

  describe "format/1" do
    test "nothing_to_fix returns success message" do
      result = Output.format(%{status: :nothing_to_fix})
      plain = strip_ansi(result)
      assert plain =~ "Nothing to fix"
      assert plain =~ "last run passed"
    end

    test "failure_found renders task box with name" do
      result =
        Output.format(%{
          status: :failure_found,
          summary: %{
            "failed_count" => 1,
            "total_count" => 3,
            "git_ref" => "abc1234",
            "git_branch" => "main"
          },
          tasks: [
            %{
              "name" => "test:auth",
              "command" => "npm test -- --filter auth",
              "exit_code" => 1,
              "locations" => [],
              "possible_causes" => ["src/auth.ts changed"],
              "suggested_fix" => "check token format",
              "hints" => [],
              "regression" => false,
              "history" => nil
            }
          ],
          diff_since_last_good: nil
        })

      plain = strip_ansi(result)

      assert plain =~ "1 of 3 tasks failed"
      assert plain =~ "fix: test:auth"
      assert plain =~ "npm test -- --filter auth"
      assert plain =~ "exit code 1"
      assert plain =~ "cause: src/auth.ts changed"
      assert plain =~ "fix:   check token format"
      # Box drawing chars
      assert result =~ "╭"
      assert result =~ "╰"
    end

    test "renders regression marker" do
      result =
        Output.format(%{
          status: :failure_found,
          summary: %{
            "failed_count" => 1,
            "total_count" => 1,
            "git_ref" => nil,
            "git_branch" => nil
          },
          tasks: [
            %{
              "name" => "build",
              "command" => "make",
              "exit_code" => 2,
              "locations" => [],
              "possible_causes" => [],
              "suggested_fix" => nil,
              "hints" => [],
              "regression" => true,
              "history" => nil
            }
          ],
          diff_since_last_good: nil
        })

      plain = strip_ansi(result)
      assert plain =~ "REGRESSION"
    end

    test "renders diff section" do
      result =
        Output.format(%{
          status: :failure_found,
          summary: %{
            "failed_count" => 1,
            "total_count" => 1,
            "git_ref" => nil,
            "git_branch" => nil
          },
          tasks: [
            %{
              "name" => "test",
              "command" => "mix test",
              "exit_code" => 1,
              "locations" => [],
              "possible_causes" => [],
              "suggested_fix" => nil,
              "hints" => [],
              "regression" => false,
              "history" => nil
            }
          ],
          diff_since_last_good: %{
            "ref" => "abc1234",
            "files" => ["src/auth.ts"],
            "stat" => "src/auth.ts | 12 +++---"
          }
        })

      plain = strip_ansi(result)
      assert plain =~ "Changes since last pass (abc1234)"
      assert plain =~ "src/auth.ts | 12 +++---"
    end

    test "renders history stats" do
      result =
        Output.format(%{
          status: :failure_found,
          summary: %{
            "failed_count" => 1,
            "total_count" => 1,
            "git_ref" => nil,
            "git_branch" => nil
          },
          tasks: [
            %{
              "name" => "test",
              "command" => "mix test",
              "exit_code" => 1,
              "locations" => [],
              "possible_causes" => [],
              "suggested_fix" => nil,
              "hints" => [],
              "regression" => false,
              "history" => %{"pass_rate" => 0.94, "streak" => 0, "flaky" => false}
            }
          ],
          diff_since_last_good: nil
        })

      plain = strip_ansi(result)
      assert plain =~ "94% pass rate"
    end
  end

  defp strip_ansi(str) do
    Regex.replace(~r/\e\[[0-9;]*m/, str, "")
  end
end
