defmodule BotArmyTerrain.Repo.Migrations.CreateReviewSessionCards do
  use Ecto.Migration

  def change do
    create table(:review_session_cards, primary_key: false, prefix: "terrain") do
      add :id, :binary_id, primary_key: true
      add :session_id, references(:review_sessions, type: :binary_id, on_delete: :delete_all, prefix: "terrain"), null: false
      add :card_id, references(:cards, type: :binary_id, on_delete: :nilify_all, prefix: "terrain")
      add :quality, :integer, null: false
      add :elapsed_ms, :integer, null: false
      add :reviewed_at, :utc_datetime_usec, null: false
    end

    create index(:review_session_cards, [:session_id], prefix: "terrain")
    create index(:review_session_cards, [:card_id], prefix: "terrain")
  end
end
