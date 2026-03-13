import Config

config :bot_army_terrain, BotArmyTerrain.Repo,
  database: System.get_env("BOT_ARMY_TERRAIN_DB_NAME", "ergon_terrain_test"),
  pool: Ecto.Adapters.SQL.Sandbox
