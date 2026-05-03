defmodule Sykli.GitHub.DispatcherTest do
  use ExUnit.Case, async: false

  alias Sykli.GitHub.Dispatcher
  alias Sykli.GitHub.Webhook.Deliveries
  alias Sykli.Occurrence.PubSub

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
               source_client: Sykli.GitHub.Source.Fake,
               source_fixture: @fixture,
               test_pid: self(),
               fake_recorder: self()
             )

    assert_receive {:github_checks_create_suite, %{repo: "false-systems/sykli"},
                    "fake-installation-token-123"}

    assert_receive {:github_checks_create_run, %{head_sha: "abc123"},
                    "fake-installation-token-123", "test"}

    assert_receive {:github_checks_update_run, %{check_run_id: _}, "fake-installation-token-123",
                    %{status: "in_progress"}}

    assert_receive {:github_checks_update_run, %{check_run_id: _}, "fake-installation-token-123",
                    %{status: "completed", conclusion: "success"}}

    assert_receive %Sykli.Occurrence{type: "ci.github.run.dispatched"}
    assert_receive %Sykli.Occurrence{type: "ci.github.run.source_acquired"}
    assert_receive %Sykli.Occurrence{type: "ci.github.check_run.created"}
    assert_receive %Sykli.Occurrence{type: "ci.github.check_suite.concluded"}
  end

  test "dispatch failure evicts the delivery for GitHub retry", %{event: event} do
    assert :ok = Deliveries.accept(event.delivery_id, 1)

    assert {:error, %Sykli.Error{code: "github.source.clone_failed"}} =
             Dispatcher.dispatch(event,
               app_client: Sykli.GitHub.App.Fake,
               checks_client: Sykli.GitHub.Checks.Fake,
               source_client: Sykli.GitHub.Source.Fake,
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
                    "fake-installation-token-123", "sykli/source"}

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
end
