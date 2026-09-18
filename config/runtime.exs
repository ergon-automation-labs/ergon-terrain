import Config

# Runtime configuration — evaluated when the app starts, not at compile time
# This allows environment variables set by launchd/Salt to be read properly

# Primary database configuration at runtime (postgres-vector, port 30006)
# Priority: BOT_ARMY_TERRAIN_DB_* (set by Salt/Jenkins) > DATABASE_* (from .env for local dev) > defaults
if config_env() != :test do
  alias BotArmyLibraryRuntime.Ecto.RuntimeDbConfig

  db_config =
    RuntimeDbConfig.resolve("BOT_ARMY_TERRAIN", database: "ergon_terrain", port: 30006)

  config(
    :bot_army_terrain,
    BotArmyTerrain.Repo,
    Keyword.merge(db_config, [
      pool_size: RuntimeDbConfig.pool_size("BOT_ARMY_TERRAIN", 15),
      ssl: false
    ])
  )

  # Learning library configuration (uses same database as this bot)
  config :bot_army_library_learning, ecto_repos: [BotArmyLearning.Repo]

  config(
    :bot_army_library_learning,
    BotArmyLearning.Repo,
    Keyword.merge(db_config, [
      pool_size: RuntimeDbConfig.pool_size("BOT_ARMY_TERRAIN", 15),
      ssl: false
    ])
  )

  # Graph database configuration at runtime (postgres-age, port 30002)
  graph_db_config =
    RuntimeDbConfig.resolve("BOT_ARMY_TERRAIN_GRAPH",
      database: "ergon_graphdb_terrain",
      port: 30002
    )

  config :bot_army_terrain,
         BotArmyTerrain.GraphRepo,
         Keyword.put(
           graph_db_config,
           :pool_size,
           RuntimeDbConfig.pool_size("BOT_ARMY_TERRAIN_GRAPH", 15)
         )
end
