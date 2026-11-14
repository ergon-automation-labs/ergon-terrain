defmodule BotArmyTerrain.Schemas.StoryProgress do
  @moduledoc "Where she is in the morning story, and what the world remembers. One row per tenant."

  use Ecto.Schema
  import Ecto.Changeset

  @schema_prefix "terrain"
  @primary_key {:id, :binary_id, autogenerate: true}

  schema "story_progress" do
    field(:tenant_id, :binary_id)
    field(:chapter, :string)
    field(:scene_id, :string)
    field(:facts, :map, default: %{})
    field(:log, {:array, :map}, default: [])
    field(:chosen_on, :date)
    field(:last_outcome, :map)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(progress, attrs) do
    progress
    |> cast(attrs, [:tenant_id, :chapter, :scene_id, :facts, :log, :chosen_on, :last_outcome])
    |> validate_required([:tenant_id, :chapter, :scene_id])
    |> unique_constraint(:tenant_id)
  end
end
