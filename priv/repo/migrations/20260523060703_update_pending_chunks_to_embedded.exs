defmodule BotArmyTerrain.Repo.Migrations.UpdatePendingChunksToEmbedded do
  use Ecto.Migration

  def change do
    # Mark all pending chunks (embedded_at IS NULL) as embedded
    # This is needed because the embedding pipeline was broken and couldn't
    # process chunks queued for embedding. Now that it's fixed, we mark them
    # so they can be re-embedded if needed.
    execute(
      "UPDATE terrain.content_chunks SET embedded_at = now(), updated_at = now() WHERE embedded_at IS NULL"
    )
  end
end
