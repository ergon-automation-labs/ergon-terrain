defmodule BotArmyTerrain.Repo.Migrations.CreateGameStates do
  use Ecto.Migration

  @prefix "terrain"

  def change do
    create table(:game_states, primary_key: false, prefix: @prefix) do
      add :id, :binary_id, primary_key: true
      add :track_id, :binary_id, null: false
      add :game_json, :text
      add :dojo_json, :text
      add :status, :string, null: false, default: "pending"
      # Status values: "generating_game" | "generating_dojo" | "active" | "stale"
      add :generated_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:game_states, [:track_id], prefix: @prefix, name: :idx_game_states_track_id_unique)
  end
end
