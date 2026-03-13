defmodule BotArmyTerrain.Repo.Migrations.CreateContentChunks do
  use Ecto.Migration

  @prefix "terrain"
  # text-embedding-3-small dimension
  @embedding_dims 1536

  def change do
    create table(:content_chunks, prefix: @prefix, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, :uuid
      add :source_type, :string, null: false
      add :source_path, :string, null: false
      add :track_id, references(:tracks, type: :uuid, prefix: @prefix), null: false
      add :content, :text, null: false
      add :content_hash, :string, null: false
      add :metadata, :map, default: %{}
      add :embedding_vector, :vector, size: @embedding_dims
      add :embedded_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:content_chunks, [:track_id, :content_hash], prefix: @prefix)
    create index(:content_chunks, [:track_id], prefix: @prefix)
    create index(:content_chunks, [:user_id], prefix: @prefix)
  end
end
