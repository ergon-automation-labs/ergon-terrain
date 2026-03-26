defmodule BotArmyTerrain.Repo.Migrations.CreateLessons do
  use Ecto.Migration

  @prefix "terrain"

  def change do
    create table(:lessons, primary_key: false, prefix: @prefix) do
      add :id, :binary_id, primary_key: true
      add :chunk_id, :binary_id, null: false
      add :title, :string, null: false
      add :explanation, :text, null: false
      add :external_link, :string, default: ""
      add :difficulty, :integer, default: 1
      add :embedding_vector, :vector, size: 1536
      add :embedded_at, :utc_datetime_usec
      add :generated_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:lessons, [:chunk_id], prefix: @prefix, name: :idx_lessons_chunk_id_unique)
    create index(:lessons, ["embedding_vector"], using: :ivfflat, prefix: @prefix, name: :idx_lessons_embedding)
  end
end
