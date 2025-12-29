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
  param(:push, :boolean, default: true, doc: "Push to registry after build")
  param(:scan, :boolean, default: false, doc: "Run security scan")

  requires([:docker])

  # Declarative task definitions
  tasks do
    task "build" do
      container "docker:24-dind"
      command "docker build -t ${image} -f ${dockerfile} ${context}"
      privileged true
      inputs ["${dockerfile}", "${context}/**/*"]
    end

    task "scan", when: {:param, :scan} do
      container "docker:24-dind"
      command "docker scout cves ${image}"
      privileged true
      depends_on ["build"]
    end

    task "push", when: {:param, :push} do
      container "docker:24-dind"
      command "docker push ${image}"
      privileged true
      depends_on ["build"]
    end
  end
end
