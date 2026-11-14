defmodule BotArmyTerrain.Repo.Migrations.CreateStoryProgress do
  @moduledoc """
  Where she is in the morning story, and what the world remembers.

  One row per tenant. `facts` is the world's memory (items carried, factions angered, doors
  opened), `log` is every choice made with its day, and `chosen_on` is the household day of the
  last choice, so a scene is one per morning.
  """
  use Ecto.Migration

  def change do
    create table(:story_progress, primary_key: false, prefix: "terrain") do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, :binary_id, null: false)
      add(:chapter, :string, null: false)
      add(:scene_id, :string, null: false)
      add(:facts, :map, null: false, default: %{})
      add(:log, {:array, :map}, null: false, default: [])
      add(:chosen_on, :date)
      add(:last_outcome, :map)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:story_progress, [:tenant_id], prefix: "terrain"))
  end
end
