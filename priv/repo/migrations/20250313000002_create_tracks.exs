defmodule BotArmyTerrain.Repo.Migrations.CreateTracks do
  use Ecto.Migration

  @prefix "terrain"

  def change do
    create table(:tracks, prefix: @prefix, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, :uuid
      add :name, :string, null: false
      add :description, :text
      add :color, :string, default: "#4a90d9"
      add :icon, :string, default: "book"
      add :status, :string, default: "active", null: false
      add :card_count, :integer, default: 0, null: false
      add :chunk_count, :integer, default: 0, null: false
      add :xp, :integer, default: 0, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:tracks, [:user_id, :status], prefix: @prefix)
  end
end
