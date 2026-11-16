defmodule BotArmyTerrain.Repo.Migrations.CreateAdEvents do
  @moduledoc """
  One row per airing, skip, answer, or start of an interstitial.

  `boundary_key` makes an event idempotent: a refresh that redraws the same chapter boundary
  cannot count the same impression twice. `occurred_on` is the household day, because the
  silence rule is measured in her days, not the server's.
  """
  use Ecto.Migration

  def change do
    create table(:ad_events, primary_key: false, prefix: "terrain") do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, :binary_id, null: false)
      add(:creative_id, :string, null: false)
      add(:kind, :string, null: false)
      add(:boundary_key, :string, null: false)
      add(:occurred_on, :date, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:ad_events, [:tenant_id, :creative_id, :kind, :boundary_key],
        prefix: "terrain"
      )
    )

    create(index(:ad_events, [:tenant_id, :kind, :inserted_at], prefix: "terrain"))
  end
end
