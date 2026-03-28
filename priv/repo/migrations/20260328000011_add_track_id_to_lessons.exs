defmodule BotArmyTerrain.Repo.Migrations.AddTrackIdToLessons do
  use Ecto.Migration

  @prefix "terrain"

  def change do
    alter table(:lessons, prefix: @prefix) do
      add :track_id, :binary_id, null: true
    end

    create index(:lessons, [:track_id], prefix: @prefix, name: :idx_lessons_track_id)
  end
end
