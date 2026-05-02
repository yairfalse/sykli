defmodule Sykli.GitHub.Source.Fake do
  @moduledoc "Fixture-backed GitHub source acquisition for tests."

  @behaviour Sykli.GitHub.Source.Behaviour

  @base_dir Path.join(System.tmp_dir!(), "sykli-runs")

  @impl true
  def acquire(context, token, opts \\ []) do
    notify(opts, {:github_source_acquire, context, token})

    case Keyword.get(opts, :source_response, :default) do
      :default -> copy_fixture(context, opts)
      response -> response
    end
  end

  @impl true
  def cleanup(path, opts \\ []) do
    notify(opts, {:github_source_cleanup, path})
    Sykli.GitHub.Source.Real.cleanup(path, opts)
  end

  defp copy_fixture(context, opts) do
    fixture = Keyword.fetch!(opts, :source_fixture)
    run_id = Map.get(context, :run_id) || Map.get(context, :delivery_id) || "fake"
    dest = Path.join([@base_dir, "fake-#{safe_segment(run_id)}", "repo"])

    File.rm_rf!(Path.dirname(dest))
    File.mkdir_p!(Path.dirname(dest))

    case File.cp_r(fixture, dest) do
      {:ok, _files} -> {:ok, dest}
      {:error, reason, file} -> {:error, source_error(file, reason)}
    end
  end

  defp safe_segment(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9._:-]/, "-")
  end

  defp source_error(file, reason) do
    %Sykli.Error{
      code: "github.source.copy_failed",
      type: :runtime,
      message: "failed to copy fixture source",
      step: :setup,
      cause: {file, reason},
      hints: []
    }
  end

  defp notify(opts, message) do
    case Keyword.get(opts, :test_pid) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end
end
