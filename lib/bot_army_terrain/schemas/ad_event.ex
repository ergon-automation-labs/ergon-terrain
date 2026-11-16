defmodule BotArmyTerrain.Schemas.AdEvent do
  @moduledoc """
  One thing that happened to one interstitial.

  The row is intentionally small: `creative_id` and `boundary_key` are the identity, `kind`
  is what happened, and `occurred_on` is the household day that the silence rule reads.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @schema_prefix "terrain"
  @primary_key {:id, :binary_id, autogenerate: true}
  @kinds ~w(impression skip answer start)

  schema "ad_events" do
    field(:tenant_id, :binary_id)
    field(:creative_id, :string)
    field(:kind, :string)
    field(:boundary_key, :string)
    field(:occurred_on, :date)

    timestamps(type: :utc_datetime_usec)
  end

  @fields [:creative_id, :kind, :boundary_key, :occurred_on]

  def fields, do: @fields
  def kinds, do: @kinds

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:tenant_id | @fields])
    |> validate_required([:tenant_id, :creative_id, :kind, :boundary_key, :occurred_on])
    |> validate_inclusion(:kind, @kinds)
    |> unique_constraint([:tenant_id, :creative_id, :kind, :boundary_key])
  end
end
