defmodule BotArmyTerrain.Repo.Migrations.AddTenantAndUserId do
  use Ecto.Migration

  def up do
    default_tenant_id = "00000000-0000-0000-0000-000000000001"

    # tracks already has user_id, so only add tenant_id
    alter table(:tracks, prefix: "terrain") do
      add :tenant_id, :uuid, null: true
    end
    create index(:tracks, [:tenant_id], prefix: "terrain")
    execute("UPDATE terrain.tracks SET tenant_id = '#{default_tenant_id}'::uuid WHERE tenant_id IS NULL")

    # content_chunks already has user_id, so only add tenant_id
    alter table(:content_chunks, prefix: "terrain") do
      add :tenant_id, :uuid, null: true
    end
    create index(:content_chunks, [:tenant_id], prefix: "terrain")
    execute("UPDATE terrain.content_chunks SET tenant_id = '#{default_tenant_id}'::uuid WHERE tenant_id IS NULL")

    # cards, review_sessions, review_session_cards, lessons, game_states need both
    for table <- [:cards, :review_sessions, :review_session_cards, :lessons, :game_states] do
      alter table(table, prefix: "terrain") do
        add :tenant_id, :uuid, null: true
        add :user_id, :uuid, null: true
      end
      create index(table, [:tenant_id], prefix: "terrain")
      create index(table, [:user_id], prefix: "terrain")
      execute("UPDATE terrain.#{table} SET tenant_id = '#{default_tenant_id}'::uuid WHERE tenant_id IS NULL")
    end
  end

  def down do
    # tracks
    drop index(:tracks, [:tenant_id], prefix: "terrain")
    alter table(:tracks, prefix: "terrain") do
      remove :tenant_id
    end

    # content_chunks
    drop index(:content_chunks, [:tenant_id], prefix: "terrain")
    alter table(:content_chunks, prefix: "terrain") do
      remove :tenant_id
    end

    # cards, review_sessions, review_session_cards, lessons, game_states
    for table <- [:cards, :review_sessions, :review_session_cards, :lessons, :game_states] do
      drop index(table, [:tenant_id], prefix: "terrain")
      drop index(table, [:user_id], prefix: "terrain")
      alter table(table, prefix: "terrain") do
        remove :tenant_id
        remove :user_id
      end
    end
  end
end
