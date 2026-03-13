defmodule BotArmyTerrain.Repo.Migrations.CreateTerrainSchemaAndVector do
  use Ecto.Migration

  def up do
    execute "CREATE SCHEMA IF NOT EXISTS terrain"
    execute "CREATE EXTENSION IF NOT EXISTS vector"
  end

  def down do
    execute "DROP EXTENSION IF EXISTS vector"
    execute "DROP SCHEMA IF EXISTS terrain CASCADE"
  end
end
