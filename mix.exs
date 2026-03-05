defmodule EctoQueryParser.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/mylanconnolly/ecto_query_parser"

  def project do
    [
      app: :ecto_query_parser,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      package: package(),
      docs: docs(),
      name: "EctoQueryParser",
      description:
        "A query language parser that converts human-readable filter strings into Ecto WHERE clauses.",
      source_url: @source_url,
      homepage_url: @source_url,
      usage_rules: usage_rules()
    ]
  end

  defp usage_rules do
    [
      file: "CLAUDE.md",
      usage_rules: :all
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "EctoQueryParser",
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ecto, "~> 3.0"},
      {:phrase_utils, "~> 0.1"},
      {:usage_rules, "~> 1.1", only: [:dev]},
      {:igniter, "~> 0.6", only: [:dev]},
      {:nimble_parsec, "~> 1.4"},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:ecto_sql, "~> 3.0", only: :test},
      {:postgrex, "~> 0.19", only: :test}
    ]
  end

  defp aliases do
    [
      "test.integration": ["test --include integration"]
    ]
  end
end
