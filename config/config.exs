import Config

# Load .env for local development
if File.exists?("config/.env") or File.exists?(".env") do
  path = if File.exists?("config/.env"), do: "config/.env", else: ".env"

  File.stream!(path)
  |> Stream.map(&String.trim_trailing/1)
  |> Stream.reject(&String.starts_with?(&1, "#"))
  |> Stream.reject(&(&1 == ""))
  |> Enum.each(fn line ->
    case String.split(line, "=", parts: 2) do
      [key, value] -> System.put_env(key, value)
      _ -> nil
    end
  end)
end

config :bot_army_terrain, :deployment_status, "experimental"

config :bot_army_terrain, ecto_repos: [BotArmyTerrain.Repo, BotArmyTerrain.GraphRepo]

# Configure library graph functions to use this bot's repo
config :bot_army_library_core, :graph_repo, BotArmyTerrain.GraphRepo

# Terrain uses its own Postgres schema "terrain" (shared instance).
# Defaults: local dev DB; override with BOT_ARMY_TERRAIN_DB_* or DATABASE_*.
config :bot_army_terrain, BotArmyTerrain.Repo,
  types: BotArmyTerrain.PostgrexTypes,
  database:
    System.get_env("BOT_ARMY_TERRAIN_DB_NAME") ||
      System.get_env("DATABASE_NAME", "ergon_terrain_dev"),
  hostname:
    System.get_env("BOT_ARMY_TERRAIN_DB_HOST") || System.get_env("DATABASE_HOST", "localhost"),
  port:
    String.to_integer(
      System.get_env("BOT_ARMY_TERRAIN_DB_PORT") || System.get_env("DATABASE_PORT", "5432")
    ),
  username:
    System.get_env("BOT_ARMY_TERRAIN_DB_USER") || System.get_env("DATABASE_USER", "postgres"),
  password:
    System.get_env("BOT_ARMY_TERRAIN_DB_PASSWORD") ||
      System.get_env("DATABASE_PASSWORD", "postgres"),
  pool_size: 15

config :logger,
  level: :info,
  backends: [:console]

config :logger, :console,
  format: "[$time] [$level] $message\n",
  metadata: [:correlation_id]

# config/{env}.exs (test.exs, dev.exs, etc.) was never imported, so any
# override it defined (most commonly a *_test database name) was dead code —
# every mix invocation used the settings above unmodified, regardless of
# MIX_ENV. Guarded by File.exists? since not every env has its own file here.
env_config = "#{config_env()}.exs"

if File.exists?(Path.join(__DIR__, env_config)) do
  import_config env_config
end

