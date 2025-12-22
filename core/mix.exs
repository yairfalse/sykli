defmodule Sykli.MixProject do
  use Mix.Project

  @version "0.1.2"

  def project do
    [
      app: :sykli,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      escript: [main_module: Sykli.CLI],
      releases: releases(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl, :public_key],
      mod: {Sykli.Application, []}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:phoenix_pubsub, "~> 2.2"},
      {:libcluster, "~> 3.3"},
      {:burrito, "~> 1.5"}
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
