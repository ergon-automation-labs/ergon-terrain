defmodule BotArmyTerrain.Repo.Migrations.CreateCards do
  use Ecto.Migration

  def change do
    create table(:cards, primary_key: false, prefix: "terrain") do
      add :id, :binary_id, primary_key: true
      add :track_id, references(:tracks, type: :binary_id, on_delete: :cascade, prefix: "terrain"), null: false
      add :chunk_id, references(:content_chunks, type: :binary_id, on_delete: :set_null, prefix: "terrain")
      add :front, :text, null: false
      add :back, :text, null: false
      add :card_type, :string, default: "basic"
      add :generation_model, :string

      # SRS Fields (SM-2)
      add :ease_factor, :float, default: 2.5
      add :interval_days, :integer, default: 1
      add :repetitions, :integer, default: 0
      add :next_review_at, :utc_datetime_usec, null: false
      add :last_reviewed_at, :utc_datetime_usec
      add :state, :string, default: "new"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:cards, [:track_id], prefix: "terrain")
    create index(:cards, [:next_review_at], prefix: "terrain")
    create index(:cards, [:state], prefix: "terrain")
    create unique_index(:cards, [:track_id, "md5(front)"], prefix: "terrain", name: :idx_cards_front_hash)
  end
end
