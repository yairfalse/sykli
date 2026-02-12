defmodule SykliSdk.MixProject do
  use Mix.Project

  def project do
    [
      app: :sykli_sdk,
      version: "0.5.3",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "CI pipelines defined in Elixir instead of YAML",
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      name: "sykli",
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/yairfalse/sykli"},
      files: ~w(lib mix.exs README.md)
    ]
  end
end
