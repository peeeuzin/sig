defmodule Sig.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/peeeuzin/sig"

  def project do
    [
      app: :sig,
      version: @version,
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      name: "Sig",
      description:
        "A resilient DAG workflow engine for Elixir, backed by Ecto (PostgreSQL) and BullMQ (Redis).",
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:bullmq, "~> 1.0"},
      {:ecto_sql, "~> 3.10"},
      {:postgrex, ">= 0.0.0"},
      {:testcontainers, "~> 2.4", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md", "LICENSE"],
      groups_for_modules: [
        "Defining workflows": [Sig.Flow, Sig.Node, Sig.NodeContext],
        Execution: [Sig.Engine, Sig.Serializer],
        "Distributed execution (BullMQ)": [
          Sig.BullMQ.Supervisor,
          Sig.BullMQ.Queue,
          Sig.BullMQ.Worker
        ],
        Persistence: [
          Sig.Repo,
          Sig.Migration,
          Sig.Schemas.Workflow,
          Sig.Schemas.WorkflowExecution,
          Sig.Schemas.NodeExecution
        ]
      ]
    ]
  end

  defp aliases do
    []
  end
end
