defmodule BotArmyTerrain.MixProject do
  @moduledoc """
  Terrain — content pipeline for the learning stack.
  Ingests markdown/CSV, chunks, embeds (pgvector), organizes tracks.
  See docs/north_star_docs/TERRAIN_NORTH_STAR.md.
  """

  use Mix.Project

  def project do
    [
      app: :bot_army_terrain,
      version: "0.2.13",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [
        terrain_bot: [
          applications: [bot_army_terrain: :permanent]
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {BotArmyTerrain.Application, []}
    ]
  end

  defp deps do
    [
      {:bot_army_core, path: "../bot_army_core"},
      {:bot_army_runtime, path: "../bot_army_runtime"},
      {:ecto_sql, "~> 3.10"},
      {:postgrex, "~> 0.17"},
      {:pgvector, "~> 0.3"},
      {:jason, "~> 1.4"},
      {:logger_json, "~> 5.1"},
      {:elixir_uuid, "~> 1.2"},
      {:yaml_elixir, "~> 2.9"},

      # Development/Test
      {:ex_doc, "~> 0.30", only: :dev},
      {:credo, "~> 1.7", only: [:dev, :test]},
      {:dialyxir, "~> 1.4", only: [:dev, :test]},
      {:excoveralls, "~> 0.17", only: :test},
      {:mox, "~> 1.0", only: :test}
    ]
  end
end
