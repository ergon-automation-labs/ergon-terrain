defmodule BotArmyTerrain.Repo.Migrations.AddEmbeddingsToCards do
  use Ecto.Migration

  def change do
    alter table(:cards, prefix: "terrain") do
      add :embedding_vector, :vector, size: 1536
      add :embedded_at, :utc_datetime_usec
    end

    create index(:cards, ["embedding_vector"], using: :ivfflat, prefix: "terrain", name: :idx_cards_embedding)
  end
end
