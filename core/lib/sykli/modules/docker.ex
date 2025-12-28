defmodule Sykli.Modules.Docker do
  @moduledoc """
  Docker module - build and push container images.

  ## Usage

      use Sykli
      import Sykli.Modules.Docker

      pipeline do
        build_and_push image: "myapp:latest"
      end

  Or programmatically:

      alias Sykli.Modules.Docker.BuildAndPush

      config = %BuildAndPush{image: "myapp:latest", push: true}
      tasks = BuildAndPush.tasks(config)
  """
end

defmodule Sykli.Modules.Docker.BuildAndPush do
  @moduledoc """
  Build and push Docker images.

  ## Parameters

  - `image` (required) - Full image name with tag (e.g., "myapp:latest")
  - `dockerfile` - Path to Dockerfile (default: "Dockerfile")
  - `context` - Build context path (default: ".")
  - `build_args` - Build arguments as map (default: %{})
  - `push` - Whether to push after build (default: true)
  - `scan` - Run security scan (default: false)

  ## Generated Tasks

  - `build` - Builds the Docker image
  - `push` - Pushes to registry (if push: true)
  - `scan` - Runs security scan (if scan: true)

  ## Example

      %BuildAndPush{
        image: "myapp:" <> git_sha(),
        push: branch() == "main",
        scan: true
      }
      |> BuildAndPush.tasks()
  """

  use Sykli.Module

  @version "1.0.0"

  param(:image, :string, required: true, doc: "Image name with tag")
  param(:dockerfile, :string, default: "Dockerfile", doc: "Path to Dockerfile")
  param(:context, :string, default: ".", doc: "Build context directory")
  param(:build_args, {:map, :string, :string}, default: %{}, doc: "Build arguments")
  param(:push, :boolean, default: true, doc: "Push to registry after build")
  param(:scan, :boolean, default: false, doc: "Run security scan")
  param(:platform, :string, default: nil, doc: "Target platform (e.g., linux/amd64)")

  requires([:docker])

  # Delegate task generation to avoid compile-time struct reference issues
  def tasks(config), do: Sykli.Modules.Docker.BuildAndPush.TaskGenerator.tasks(config)
end

defmodule Sykli.Modules.Docker.BuildAndPush.TaskGenerator do
  @moduledoc false
  # Separated to avoid compile-time struct issues

  alias Sykli.Modules.Docker.BuildAndPush

  def tasks(config) when is_struct(config, BuildAndPush) do
    config = apply_defaults(config)

    case BuildAndPush.validate(config) do
      :ok -> do_generate_tasks(config)
      {:error, errors} -> raise ArgumentError, format_errors(errors)
    end
  end

  defp apply_defaults(config) do
    %{
      config
      | dockerfile: config.dockerfile || "Dockerfile",
        context: config.context || ".",
        build_args: config.build_args || %{},
        push: if(is_nil(config.push), do: true, else: config.push),
        scan: config.scan || false
    }
  end

  defp format_errors(errors) do
    errors
    |> Enum.map(fn {field, msg} -> "#{field} #{msg}" end)
    |> Enum.join(", ")
  end

  defp do_generate_tasks(config) do
    tasks = [build_task(config)]

    tasks =
      if config.scan do
        tasks ++ [scan_task(config)]
      else
        tasks
      end

    tasks =
      if config.push do
        # Push depends on build (and scan if enabled)
        deps = if config.scan, do: ["build", "scan"], else: ["build"]
        tasks ++ [push_task(config, deps)]
      else
        tasks
      end

    tasks
  end

  defp build_task(config) do
    cmd = build_command(config)

    %{
      name: "build",
      module: "docker",
      command: cmd,
      container: "docker:24-dind",
      privileged: true,
      depends_on: [],
      env: %{},
      inputs: [config.dockerfile, config.context <> "/**/*"],
      outputs: %{}
    }
  end

  defp scan_task(config) do
    %{
      name: "scan",
      module: "docker",
      command: "docker scout cves #{config.image}",
      container: "docker:24-dind",
      privileged: true,
      depends_on: ["build"],
      env: %{},
      inputs: [],
      outputs: %{}
    }
  end

  defp push_task(config, deps) do
    %{
      name: "push",
      module: "docker",
      command: "docker push #{config.image}",
      container: "docker:24-dind",
      privileged: true,
      depends_on: deps,
      env: %{},
      inputs: [],
      outputs: %{}
    }
  end

  defp build_command(config) do
    parts = ["docker build"]

    parts =
      if config.platform do
        parts ++ ["--platform #{config.platform}"]
      else
        parts
      end

    parts = parts ++ ["-t #{config.image}"]
    parts = parts ++ ["-f #{config.dockerfile}"]

    parts =
      Enum.reduce(config.build_args, parts, fn {k, v}, acc ->
        acc ++ ["--build-arg #{k}=#{v}"]
      end)

    parts = parts ++ [config.context]

    Enum.join(parts, " ")
  end
end
