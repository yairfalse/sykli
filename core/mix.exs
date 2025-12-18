defmodule Sykli.MixProject do
  use Mix.Project

  def project do
    [
      app: :sykli,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      escript: [main_module: Sykli.CLI],
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
      {:libcluster, "~> 3.3"}
    ]
  end
end
