defmodule Mix.Tasks.Sykli.Gen.Module do
  @moduledoc """
  Generates SDK code from a Sykli module definition.

  ## Usage

      mix sykli.gen.module Sykli.Modules.Docker.BuildAndPush
      mix sykli.gen.module Sykli.Modules.Docker.BuildAndPush --sdk=go
      mix sykli.gen.module Sykli.Modules.Docker.BuildAndPush --sdk=go,rust

  ## Options

    * `--sdk` - Comma-separated list of SDKs to generate (default: go,rust)
    * `--output` - Output directory (default: ./generated)

  ## Examples

      # Generate Go and Rust SDKs
      mix sykli.gen.module Sykli.Modules.Docker.BuildAndPush

      # Generate only Go SDK
      mix sykli.gen.module Sykli.Modules.Docker.BuildAndPush --sdk=go

      # Custom output directory
      mix sykli.gen.module Sykli.Modules.Docker.BuildAndPush --output=../sdk
  """

  use Mix.Task

  @shortdoc "Generate SDK code from a Sykli module"

  @impl Mix.Task
  def run(args) do
    {opts, args, _} =
      OptionParser.parse(args,
        strict: [sdk: :string, output: :string],
        aliases: [s: :sdk, o: :output]
      )

    case args do
      [module_name] ->
        generate(module_name, opts)

      [] ->
        Mix.shell().error("Usage: mix sykli.gen.module MODULE_NAME [--sdk=go,rust]")
        exit({:shutdown, 1})

      _ ->
        Mix.shell().error("Expected exactly one module name")
        exit({:shutdown, 1})
    end
  end

  defp generate(module_name, opts) do
    # Ensure the project is compiled
    Mix.Task.run("compile", [])

    # Parse module name to atom
    module =
      module_name
      |> String.split(".")
      |> Module.concat()

    # Verify module exists and has the right callbacks
    unless Code.ensure_loaded?(module) do
      Mix.shell().error("Module #{module_name} not found")
      exit({:shutdown, 1})
    end

    unless function_exported?(module, :to_json, 0) do
      Mix.shell().error("Module #{module_name} does not implement to_json/0")
      Mix.shell().error("Make sure it uses `use Sykli.Module`")
      exit({:shutdown, 1})
    end

    # Get module JSON schema
    schema = module.to_json()

    # Determine which SDKs to generate
    sdks =
      opts
      |> Keyword.get(:sdk, "go,rust")
      |> String.split(",")
      |> Enum.map(&String.trim/1)

    output_dir = Keyword.get(opts, :output, "./generated")

    # Generate each SDK
    Enum.each(sdks, fn sdk ->
      case sdk do
        "go" ->
          generate_go(schema, output_dir)

        "rust" ->
          generate_rust(schema, output_dir)

        other ->
          Mix.shell().error("Unknown SDK: #{other}")
      end
    end)

    Mix.shell().info("Done!")
  end

  defp generate_go(schema, output_dir) do
    case Sykli.Module.Codegen.Go.generate(schema) do
      {:ok, code, path} ->
        full_path = Path.join(output_dir, path)
        File.mkdir_p!(Path.dirname(full_path))
        File.write!(full_path, code)
        Mix.shell().info("Generated #{full_path}")

      {:error, reason} ->
        Mix.shell().error("Failed to generate Go: #{reason}")
    end
  end

  defp generate_rust(schema, output_dir) do
    case Sykli.Module.Codegen.Rust.generate(schema) do
      {:ok, code, path} ->
        full_path = Path.join(output_dir, path)
        File.mkdir_p!(Path.dirname(full_path))
        File.write!(full_path, code)
        Mix.shell().info("Generated #{full_path}")

      {:error, reason} ->
        Mix.shell().error("Failed to generate Rust: #{reason}")
    end
  end
end
