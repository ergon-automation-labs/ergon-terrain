defmodule BotArmyTerrain.Repo.Migrations.CreateReviewSessions do
  use Ecto.Migration

  def change do
    create table(:review_sessions, primary_key: false, schema: "terrain") do
      add :id, :binary_id, primary_key: true
      add :track_id, references(:tracks, type: :binary_id, on_delete: :cascade), null: false
      add :state, :string, default: "active"
      add :cards_reviewed, :integer, default: 0
      add :cards_correct, :integer, default: 0
      add :started_at, :utc_datetime_usec, null: false
      add :ended_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:review_sessions, [:track_id], schema: "terrain")
    create index(:review_sessions, [:state], schema: "terrain")
  end
end
