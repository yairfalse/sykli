defmodule Sykli.CLI.RendererTest do
  use ExUnit.Case, async: true

  alias Sykli.CLI.Renderer
  alias Sykli.Executor.TaskResult

  test "renders passing run without banned internal vocabulary" do
    output =
      Renderer.render_run(
        "parallel_tasks.exs",
        "local",
        "0.6.0",
        [
          %TaskResult{name: "task_a", command: "echo a", status: :passed, duration_ms: 108},
          %TaskResult{name: "task_b", command: "echo b", status: :passed, duration_ms: 112}
        ],
        111
      )
      |> IO.iodata_to_binary()

    assert output =~ "sykli · parallel_tasks.exs"
    assert output =~ "  ●  task_a"
    assert output =~ "  ─  2 passed"

    refute output =~ "Level"
    refute output =~ "1L"
    refute output =~ "(first run)"
    refute output =~ "Target: local (docker:"
    refute output =~ "All tasks completed"
  end

  test "renders failure block with output excerpt and fix hint" do
    output =
      Renderer.render_run(
        "build.exs",
        "local",
        "0.6.0",
        [
          %TaskResult{name: "test", command: "go test ./...", status: :passed, duration_ms: 1800},
          %TaskResult{
            name: "build",
            command: "go build ./cmd/app",
            status: :failed,
            duration_ms: 912,
            output: "old\n./cmd/app/main.go:42:13: undefined: ResolveOpts\n"
          },
          %TaskResult{
            name: "lint",
            command: "golangci-lint",
            status: :blocked,
            duration_ms: 0
          }
        ],
        2700
      )
      |> IO.iodata_to_binary()

    assert output =~ "  ✕  build"
    assert output =~ "  ─  1 failed · 1 passed · 1 blocked"
    assert output =~ "./cmd/app/main.go:42:13: undefined: ResolveOpts"
    assert output =~ "Run  sykli fix  for AI-readable analysis."
  end
end
