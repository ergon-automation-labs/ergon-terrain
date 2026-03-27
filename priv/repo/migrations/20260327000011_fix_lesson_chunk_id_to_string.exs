defmodule BotArmyTerrain.Repo.Migrations.FixLessonChunkIdToString do
  use Ecto.Migration

  def change do
    alter table(:lessons, prefix: "terrain") do
      modify :chunk_id, :string
    end
  end
end
