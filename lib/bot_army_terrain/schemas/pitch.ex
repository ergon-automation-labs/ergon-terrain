defmodule BotArmyTerrain.Schemas.Pitch do
  @moduledoc """
  One purpose spot's state for one GTD project.

  `why` is her sentence, in her words. When it is absent the card asks for it
  instead of airing a spot. `status` is `ready` or `retired`; a retired why is
  not a failed project, it is a reason that stopped being true.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @schema_prefix "terrain"
  @primary_key {:id, :binary_id, autogenerate: true}

  schema "pitches" do
    field(:tenant_id, :binary_id)
    field(:project_id, :string)
    field(:why, :string)
    field(:next_action, :string)
    field(:area, :string)
    field(:status, :string, default: "ready")
    field(:shown_count, :integer, default: 0)
    field(:start_count, :integer, default: 0)
    field(:last_shown_at, :utc_datetime_usec)
    field(:last_shown_on, :date)
    field(:last_started_at, :utc_datetime_usec)
    field(:snoozed_until, :utc_datetime_usec)
    field(:retired_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @fields [
    :project_id,
    :why,
    :next_action,
    :area,
    :status,
    :shown_count,
    :start_count,
    :last_shown_at,
    :last_shown_on,
    :last_started_at,
    :snoozed_until,
    :retired_at
  ]

  def fields, do: @fields

  def changeset(pitch, attrs) do
    pitch
    |> cast(attrs, [:tenant_id | @fields])
    |> validate_required([:tenant_id, :project_id])
    |> validate_inclusion(:status, ["ready", "retired"])
    |> unique_constraint([:tenant_id, :project_id])
  end
end
