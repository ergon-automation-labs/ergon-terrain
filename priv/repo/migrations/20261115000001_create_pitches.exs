defmodule BotArmyTerrain.Repo.Migrations.CreatePitches do
  @moduledoc """
  The purpose spots: one row per GTD project, holding the why she wrote and when it aired.

  `why` is an override, not the source of truth — the project's own `metadata["why"]`
  still belongs to the project. This row caches it so a spot can be selected and served
  without a round trip to the GTD bot.

  `last_shown_on` is the household day, so a refresh cannot air the same pitch twice in
  one day. `snoozed_until` is a first-class answer: "not now" writes a date, not a
  judgement.
  """
  use Ecto.Migration

  def change do
    create table(:pitches, primary_key: false, prefix: "terrain") do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, :binary_id, null: false)
      add(:project_id, :string, null: false)
      add(:why, :string)
      add(:next_action, :string)
      add(:area, :string)
      add(:status, :string, null: false, default: "ready")
      add(:shown_count, :integer, null: false, default: 0)
      add(:start_count, :integer, null: false, default: 0)
      add(:last_shown_at, :utc_datetime_usec)
      add(:last_shown_on, :date)
      add(:last_started_at, :utc_datetime_usec)
      add(:snoozed_until, :utc_datetime_usec)
      add(:retired_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:pitches, [:tenant_id, :project_id], prefix: "terrain"))
  end
end
