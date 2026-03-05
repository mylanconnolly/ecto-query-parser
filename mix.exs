defmodule EctoQueryParser.MixProject do
  use Mix.Project

  def project do
    [
      app: :ecto_query_parser,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      usage_rules: usage_rules()
    ]
  end

  defp usage_rules do
    [
      file: "CLAUDE.md",
      usage_rules: :all
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
