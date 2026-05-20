import Config

# Runtime configuration — evaluated when the app starts, not at compile time
# This allows environment variables set by launchd/Salt to be read properly

# Primary database configuration at runtime (postgres-vector, port 30003)
# Priority: BOT_ARMY_TERRAIN_DB_* (set by Salt/Jenkins) > DATABASE_* (from .env for local dev) > defaults
config :bot_army_terrain, BotArmyTerrain.Repo,
  database:
    System.get_env("BOT_ARMY_TERRAIN_DB_NAME") || System.get_env("DATABASE_NAME") ||
      "ergon_terrain",
  hostname:
    System.get_env("BOT_ARMY_TERRAIN_DB_HOST") || System.get_env("DATABASE_HOST") || "localhost",
  port:
    String.to_integer(
      System.get_env("BOT_ARMY_TERRAIN_DB_PORT") || System.get_env("DATABASE_PORT") || "30003"
    ),
  username:
    System.get_env("BOT_ARMY_TERRAIN_DB_USER") || System.get_env("DATABASE_USER") || "postgres",
  password:
    System.get_env("BOT_ARMY_TERRAIN_DB_PASSWORD") || System.get_env("DATABASE_PASSWORD") ||
      "postgres",
  pool_size: 3,
  ssl: false

# Learning library configuration (uses same database as this bot)
config :bot_army_learning, ecto_repos: [BotArmyLearning.Repo]

config :bot_army_learning, BotArmyLearning.Repo,
  database:
    System.get_env("BOT_ARMY_TERRAIN_DB_NAME") || System.get_env("DATABASE_NAME") ||
      "ergon_terrain",
  hostname:
    System.get_env("BOT_ARMY_TERRAIN_DB_HOST") || System.get_env("DATABASE_HOST") || "localhost",
  port:
    String.to_integer(
      System.get_env("BOT_ARMY_TERRAIN_DB_PORT") || System.get_env("DATABASE_PORT") || "30003"
    ),
  username:
    System.get_env("BOT_ARMY_TERRAIN_DB_USER") || System.get_env("DATABASE_USER") || "postgres",
  password:
    System.get_env("BOT_ARMY_TERRAIN_DB_PASSWORD") || System.get_env("DATABASE_PASSWORD") ||
      "postgres",
  pool_size: 3,
  ssl: false

# Graph database configuration at runtime (postgres-age, port 30002)
# Priority: GRAPHDB_* (set by Salt) > defaults
# Uses per-bot database name: ergon_graphdb_terrain (not shared ergon_graphs)
config :bot_army_core, BotArmyCore.GraphRepo,
  hostname: System.get_env("GRAPHDB_HOST", "localhost"),
  port: String.to_integer(System.get_env("GRAPHDB_PORT", "30002")),
  username: System.get_env("GRAPHDB_USER", "postgres"),
  password: System.get_env("GRAPHDB_PASSWORD", "postgres"),
  database: System.get_env("GRAPHDB_NAME", "ergon_graphdb_terrain"),
  pool_size: 2
