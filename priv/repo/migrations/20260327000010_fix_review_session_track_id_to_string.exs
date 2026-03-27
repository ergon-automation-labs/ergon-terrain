defmodule BotArmyTerrain.Repo.Migrations.FixReviewSessionTrackIdToString do
  use Ecto.Migration

  def change do
    alter table(:review_sessions, prefix: "terrain") do
      modify :track_id, :string
    end
  end
end
