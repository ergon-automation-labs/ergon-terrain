defmodule BotArmyTerrain.Repo.Migrations.EnforceTenantNotNull do
  use Ecto.Migration

  def up do
    # Terrain schema requires prefixed table names in raw SQL
    for table <- [:tracks, :content_chunks, :cards, :review_sessions, :review_session_cards, :lessons, :game_states] do
      execute("ALTER TABLE terrain.#{table} ALTER COLUMN tenant_id SET NOT NULL")
    end
  end

  def down do
    for table <- [:tracks, :content_chunks, :cards, :review_sessions, :review_session_cards, :lessons, :game_states] do
      execute("ALTER TABLE terrain.#{table} ALTER COLUMN tenant_id DROP NOT NULL")
    end
  end
end
