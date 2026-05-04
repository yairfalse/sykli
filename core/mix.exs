defmodule Sykli.MixProject do
  use Mix.Project

  @version "0.6.1"

  def project do
    [
      app: :sykli,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      escript: [main_module: Sykli.CLI],
      releases: releases(),
      deps: deps(),
      aliases: aliases()
    ]
  end

  def cli do
    [
      preferred_envs: [
        "test.docker": :test,
        "test.integration": :test,
        "test.podman": :test
      ]
    ]
  end

  defp aliases do
    [
      "test.docker": ["test --only docker"],
      "test.integration": ["test --only integration"],
      "test.podman": ["test --only podman"]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl, :public_key, :xmerl],
      mod: {Sykli.Application, []}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:phoenix_pubsub, "~> 2.2"},
      {:bandit, "~> 1.5"},
      {:joken, "~> 2.6"},
      {:libcluster, "~> 3.3"},
      {:burrito, "~> 1.5"},
      {:yaml_elixir, "~> 2.9"},
      {:file_system, "~> 1.0"},
      {:telemetry, "~> 1.3"},
      {:credo, "~> 1.7", runtime: false},
      {:mix_audit, "~> 2.1", only: :dev, runtime: false},
      {:stream_data, "~> 1.1", only: :test}
    ]
  end

  defp releases do
    [
      sykli: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            linux_x86_64: [os: :linux, cpu: :x86_64],
            linux_aarch64: [os: :linux, cpu: :aarch64],
            macos_x86_64: [os: :darwin, cpu: :x86_64],
            macos_aarch64: [os: :darwin, cpu: :aarch64],
            windows_x86_64: [os: :windows, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end
end
