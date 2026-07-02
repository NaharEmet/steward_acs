defmodule Acs.MixProject do
  use Mix.Project

  def project do
    [
      app: :steward_acs,
      version: "0.1.0",
      elixir: "~> 1.17",
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      build_per_environment: false,
      deps: deps(),
      aliases: aliases(),
      preferred_cli_env: [test: :test],
      releases: [
        steward_acs: [
          include_executables_for: [:unix],
          steps: [:assemble],
          validate_compile_env: false
        ]
      ]
    ]
  end

  def application do
    [
      mod: {Acs.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    # External app dependency: anantha_json if available as sibling project
    llm_utils_dep = if File.dir?("../../lib/anantha_json") do
      {:llm_utils, path: "../../lib/anantha_json", override: true}
    else
      {:llm_utils, "~> 0.1.1"}
    end

    [
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, "~> 0.22"},
      {:postgrex, "~> 0.19", only: [:prod]},
      {:jason, "~> 1.2"},
      {:req, "~> 0.5.0"},
      {:req_llm, ">= 1.0.0"},
      llm_utils_dep,
      {:dotenvy, "~> 1.0", override: true},
      {:yaml_elixir, "~> 2.9"},
      {:bandit, "~> 1.5"},
      {:phoenix, "~> 1.8.3"},
      {:phoenix_pubsub, "~> 2.2"},
      {:phoenix_live_view, "~> 1.1"},
      {:phoenix_html, "~> 4.1"},
      {:gettext, "~> 0.26"},
      {:file_system, "~> 1.0", override: true},
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},
      {:esbuild, "~> 0.8", runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:cors_plug, "~> 3.0"}
    ]
  end

  defp aliases do
    [
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      setup: ["deps.get", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate", "test"],
      "assets.deploy": ["esbuild steward_acs --minify", "phx.digest"]
    ]
  end
end
