defmodule Iso8583.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_iso8583,
      version: "0.4.0",
      elixir: "~> 1.9",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      description: description(),
      package: package(),
      name: "ExIso8583"
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:stream_data, "~> 1.2"},
      {:plug, "~> 1.15", optional: true},
      {:bandit, "~> 1.5", optional: true},
      {:jason, "~> 1.4", optional: true},
      {:ex_doc, "~> 0.30", only: :dev, runtime: false}
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end

  # Run "mix docs" to generate documentation.
  defp docs do
    [
      name: "ExIso8583",
      source_url: "https://github.com/haimiyahya/ex_iso8583",
      homepage_url: "https://github.com/haimiyahya/ex_iso8583",
      main: "readme",
      extras: ["README.md"],
      groups_for_modules: [
        "Core Types": [
          ISOMsg,
          IsoBitmap
        ],
        "Field Processing": [
          IsoField
        ],
        "Utilities": [
          Util
        ]
      ]
    ]
  end

  # Hex.pm package description
  defp description do
    """
    An ISO 8583 library for Elixir with field definitions, encoding/decoding,
    transaction processing, and pluggable transports (TCP, HTTP, UDP).
    """
  end

  # Hex.pm package configuration
  defp package do
    [
      name: "ex_iso8583",
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/haimiyahya/ex_iso8583",
        "HexDocs" => "https://hexdocs.pm/ex_iso8583"
      },
      files: ~w(lib mix.exs README.md LICENSE)
    ]
  end
end
