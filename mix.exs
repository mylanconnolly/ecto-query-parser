defmodule EctoQueryParser.MixProject do
  use Mix.Project

  def project do
    [
      app: :ecto_query_parser,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      usage_rules: usage_rules()
    ]
  end

  defp usage_rules do
    [
      file: "CLAUDE.md",
      usage_rules: :all
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
      {:ecto, "~> 3.0"},
      {:phrase_utils, "~> 0.1"},
      {:usage_rules, "~> 1.1", only: [:dev]},
      {:igniter, "~> 0.6", only: [:dev]},
      {:nimble_parsec, "~> 1.4"}
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end
end
