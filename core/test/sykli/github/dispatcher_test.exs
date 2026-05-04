defmodule Sykli.GitHub.DispatcherTest do
  use ExUnit.Case, async: false

  alias Sykli.GitHub.Dispatcher
  alias Sykli.GitHub.Webhook.Deliveries
  alias Sykli.Occurrence.PubSub
  alias Sykli.Executor.TaskResult

  @fixture Path.expand("../../../priv/test_fixtures/github_source/simple", __DIR__)

  setup do
    Deliveries.clear()
    PubSub.subscribe()

    on_exit(fn ->
      PubSub.unsubscribe()
      Deliveries.clear()
    end)

    event = %{
      event: "pull_request",
      delivery_id: "dispatcher-delivery",
      repo: "false-systems/sykli",
      installation_id: 123,
      head_sha: "abc123"
    }

    {:ok, event: event}
  end

  test "dispatch creates per-task check runs and transitions them", %{event: event} do
    assert :ok =
             Dispatcher.dispatch(event,
               app_client: Sykli.GitHub.App.Fake,
               checks_client: Sykli.GitHub.Checks.Fake,
               source_impl: Sykli.GitHub.Source.Fake,
               source_fixture: @fixture,
               test_pid: self(),
               fake_recorder: self()
             )

    assert_receive {:github_checks_create_suite, %{repo: "false-systems/sykli"},
                    "fake-installation-token-123"}

    assert_receive {:github_checks_create_run, %{head_sha: "abc123"},
                    "fake-installation-token-123", "test", "in_progress"}

    assert_receive {:github_checks_update_run, %{check_run_id: _}, "fake-installation-token-123",
                    %{status: "completed", conclusion: "success"}}

    # The completed update proves synchronous Checks calls have finished; any old
    # queued -> in_progress update would already be in the mailbox.
    refute_received {:github_checks_update_run, %{check_run_id: _}, "fake-installation-token-123",
                     %{status: "in_progress"}}

    assert_receive %Sykli.Occurrence{type: "ci.github.run.dispatched"}
    assert_receive %Sykli.Occurrence{type: "ci.github.run.source_acquired"}
    assert_receive %Sykli.Occurrence{type: "ci.github.check_run.created"}
    assert_receive %Sykli.Occurrence{type: "ci.github.check_suite.concluded"}
    assert_receive {:github_source_cleanup, source_path}
    refute File.exists?(source_path)
  end

  test "dispatch failure evicts the delivery for GitHub retry", %{event: event} do
    assert :ok = Deliveries.accept(event.delivery_id, 1)

    assert {:error, %Sykli.Error{code: "github.source.clone_failed"}} =
             Dispatcher.dispatch(event,
               app_client: Sykli.GitHub.App.Fake,
               checks_client: Sykli.GitHub.Checks.Fake,
               source_impl: Sykli.GitHub.Source.Fake,
               test_pid: self(),
               source_response:
                 {:error,
                  %Sykli.Error{
                    code: "github.source.clone_failed",
                    type: :runtime,
                    message: "clone failed",
                    step: :setup,
                    hints: []
                  }}
             )

    assert_receive {:github_checks_create_run, %{head_sha: "abc123"},
                    "fake-installation-token-123", "sykli/source", "queued"}

    assert_receive {:github_checks_update_run, %{check_run_id: _}, "fake-installation-token-123",
                    %{status: "completed", conclusion: "failure"}}

    assert_receive %Sykli.Occurrence{type: "ci.github.run.source_failed"}
    assert_receive %Sykli.Occurrence{type: "ci.github.check_suite.concluded"}

    assert :ok = Deliveries.accept(event.delivery_id, 2)
  end

  test "GitHub App config failures do not evict the delivery", %{event: event} do
    assert :ok = Deliveries.accept(event.delivery_id, 1)

    assert {:error, %Sykli.Error{code: "github.app.missing_config"}} =
             Dispatcher.dispatch(event,
               app_client: Sykli.GitHub.App.Fake,
               app_response:
                 {:error,
                  %Sykli.Error{
                    code: "github.app.missing_config",
                    type: :runtime,
                    message: "SYKLI_GITHUB_APP_ID is required",
                    step: :setup,
                    hints: []
                  }}
             )

    assert {:error, :duplicate_delivery} = Deliveries.accept(event.delivery_id, 2)
  end

  test "GitHub App authorization failures do not evict the delivery", %{event: event} do
    assert :ok = Deliveries.accept(event.delivery_id, 1)

    assert {:error, %Sykli.Error{code: "github.app.unauthorized"}} =
             Dispatcher.dispatch(event,
               app_client: Sykli.GitHub.App.Fake,
               app_response:
                 {:error,
                  %Sykli.Error{
                    code: "github.app.unauthorized",
                    type: :runtime,
                    message: "GitHub installation token request failed",
                    step: :setup,
                    hints: []
                  }}
             )

    assert {:error, :duplicate_delivery} = Deliveries.accept(event.delivery_id, 2)
  end

  test "GitHub App transport failures evict the delivery for GitHub retry", %{event: event} do
    assert :ok = Deliveries.accept(event.delivery_id, 1)

    assert {:error, %Sykli.Error{code: "github.app.transport_failed"}} =
             Dispatcher.dispatch(event,
               app_client: Sykli.GitHub.App.Fake,
               app_response:
                 {:error,
                  %Sykli.Error{
                    code: "github.app.transport_failed",
                    type: :runtime,
                    message: "GitHub installation token request could not reach GitHub",
                    step: :setup,
                    hints: []
                  }}
             )

    assert :ok = Deliveries.accept(event.delivery_id, 2)
  end

  test "dispatch cleans up the source workspace when the dispatcher process is killed", %{
    event: event
  } do
    parent = self()
    event = %{event | delivery_id: "dispatcher-crash-cleanup"}

    dispatcher =
      spawn(fn ->
        Dispatcher.dispatch(event,
          app_client: Sykli.GitHub.App.Fake,
          checks_client: Sykli.GitHub.Checks.Fake,
          source_impl: Sykli.GitHub.Source.Fake,
          source_fixture: @fixture,
          after_source_acquired: fn source_path ->
            send(parent, {:source_acquired, self(), source_path})

            receive do
              :continue -> :ok
            end
          end
        )
      end)

    assert_receive {:source_acquired, ^dispatcher, source_path}
    assert File.exists?(source_path)

    Process.exit(dispatcher, :kill)

    assert_eventually(fn ->
      refute File.exists?(source_path)
    end)
  end

  test "dispatch cleans up the source workspace if janitor startup fails", %{event: event} do
    event = %{event | delivery_id: "dispatcher-janitor-start-failed"}

    assert {:error, %Sykli.Error{code: "github.dispatch.workspace_janitor_failed"}} =
             Dispatcher.dispatch(event,
               app_client: Sykli.GitHub.App.Fake,
               checks_client: Sykli.GitHub.Checks.Fake,
               source_impl: Sykli.GitHub.Source.Fake,
               source_fixture: @fixture,
               workspace_janitor: __MODULE__.FailingJanitor,
               test_pid: self()
             )

    assert_receive {:github_source_cleanup, source_path}
    refute File.exists?(source_path)
  end

  test "suite conclusion follows per-task check-run conclusions" do
    assert Dispatcher.suite_conclusion([]) == "success"

    assert Dispatcher.suite_conclusion([
             task_result("test", :skipped),
             task_result("lint", :skipped)
           ]) == "skipped"

    assert Dispatcher.suite_conclusion([
             task_result("test", :passed),
             task_result("deploy", :blocked)
           ]) == "cancelled"

    assert Dispatcher.suite_conclusion([
             task_result("test", :failed),
             task_result("deploy", :blocked)
           ]) == "failure"
  end

  defp assert_eventually(fun, attempts_left \\ 50)

  defp assert_eventually(fun, attempts_left) when attempts_left > 0 do
    try do
      fun.()
    rescue
      ExUnit.AssertionError ->
        Process.sleep(20)
        assert_eventually(fun, attempts_left - 1)
    end
  end

  defp assert_eventually(fun, 0), do: fun.()

  defp task_result(name, status) do
    %TaskResult{name: name, status: status, duration_ms: 1}
  end

  defmodule FailingJanitor do
    def start(_owner, _path, _opts), do: {:error, :process_limit}
    def cleanup(_pid), do: :ok
  end
end
