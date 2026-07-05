defmodule Sykli.CLI.Gui do
  @moduledoc """
  `sykli gui` — boots the local Workbench for the current repo.

  Local-first only: binds 127.0.0.1 (not configurable), no auth, no
  cloud. Serves the embedded SPA plus the JSON API from
  `Sykli.Gui.Router`; data comes from the configured
  `Sykli.Gui.Provider` — the artifact provider (real `.sykli/` data) by
  default, the demo provider with `--demo`.
  """

  alias Sykli.CLI.JsonResponse

  @default_port 8621

  def main(args) do
    case parse(args) do
      {:ok, opts} ->
        start(opts)

      {:error, reason} ->
        output_error(reason, json?(args))
    end
  end

  defp start(opts) do
    port = Keyword.fetch!(opts, :port)
    json? = Keyword.fetch!(opts, :json)

    provider =
      if Keyword.fetch!(opts, :demo),
        do: Sykli.Gui.Provider.Demo,
        else: Sykli.Gui.Provider.Artifact

    Application.put_env(:sykli, :gui_provider, provider)

    case Bandit.start_link(plug: Sykli.Gui.Router, ip: {127, 0, 0, 1}, port: port) do
      {:ok, _pid} ->
        url = "http://127.0.0.1:#{port}"

        if json? do
          IO.puts(JsonResponse.ok(%{source: "gui", status: "running", url: url, port: port}))
        else
          IO.puts("Sykli Workbench listening on #{url}")
          IO.puts("provider: #{provider_label()}")
        end

        if Keyword.fetch!(opts, :open), do: open_browser(url)

        Process.sleep(:infinity)
        0

      {:error, {:shutdown, {:failed_to_start_child, :listener, :eaddrinuse}}} ->
        output_error("port #{port} is already in use; pass --port <n>", json?)

      {:error, reason} ->
        output_error("failed to start workbench: #{inspect(reason)}", json?)
    end
  end

  defp parse(args), do: parse(args, port: @default_port, open: true, json: false, demo: false)

  defp parse([], opts), do: {:ok, opts}

  defp parse(["--port", value | rest], opts) do
    case Integer.parse(value) do
      {port, ""} when port in 1..65_535 -> parse(rest, Keyword.put(opts, :port, port))
      _ -> {:error, "invalid --port value: #{value}"}
    end
  end

  defp parse(["--no-open" | rest], opts), do: parse(rest, Keyword.put(opts, :open, false))
  defp parse(["--demo" | rest], opts), do: parse(rest, Keyword.put(opts, :demo, true))
  defp parse(["--json" | rest], opts), do: parse(rest, Keyword.put(opts, :json, true))
  defp parse([flag | _rest], _opts), do: {:error, "unknown gui flag: #{flag}"}

  defp json?(args), do: "--json" in args

  defp provider_label do
    case Sykli.Gui.Provider.current() do
      Sykli.Gui.Provider.Demo -> "demo (fake data)"
      Sykli.Gui.Provider.Artifact -> "artifact (local .sykli/ data)"
      module -> inspect(module)
    end
  end

  defp open_browser(url) do
    command =
      case :os.type() do
        {:unix, :darwin} -> {"open", [url]}
        {:unix, _} -> {"xdg-open", [url]}
        _ -> nil
      end

    with {cmd, args} <- command,
         path when is_binary(path) <- System.find_executable(cmd) do
      System.cmd(path, args, stderr_to_stdout: true)
    end

    :ok
  end

  defp output_error(message, true) do
    IO.puts(JsonResponse.error(message))
    1
  end

  defp output_error(message, _json?) do
    IO.puts(:stderr, "Error: #{message}")
    1
  end
end
