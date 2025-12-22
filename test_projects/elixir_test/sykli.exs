# Test all Elixir SDK features
sdk_path = Path.join([Path.dirname(__ENV__.file), "..", "..", "sdk", "elixir"])

Mix.install([
  {:sykli, path: sdk_path}
])

defmodule Pipeline do
  use Sykli

  pipeline do
    # Basic task
    task "echo" do
      run "echo 'Hello from Elixir SDK'"
    end

    # Task with inputs (caching)
    task "cached" do
      run "echo 'This should cache'"
      inputs ["sykli.exs"]
    end

    # Task with dependency
    task "dependent" do
      run "echo 'Runs after echo'"
      after_ ["echo"]
    end

    # Task with retry (will succeed on first try)
    task "retry_test" do
      run "echo 'Testing retry'"
      retry 2
    end

    # Task with timeout
    task "timeout_test" do
      run "echo 'Quick task'"
      timeout 30
    end

    # Task with condition (should run - we're not in CI)
    task "conditional" do
      run "echo 'Condition: not CI'"
      when_ "ci != true"
    end

    # Task that depends on multiple
    task "final" do
      run "echo 'All features work!'"
      after_ ["cached", "dependent", "retry_test", "timeout_test", "conditional"]
    end
  end
end
