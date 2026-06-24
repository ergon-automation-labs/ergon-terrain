defmodule BotArmyTerrain.Schemas.Track do
  @moduledoc """
  Learning track — a topic area the user is studying (e.g. "Elixir Bootcamp", "Greek").
  Dungeon overworld uses tracks as zones/dungeon sites.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @schema_prefix "terrain"
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "tracks" do
    field(:tenant_id, :binary_id)
    field(:user_id, :binary_id)
    field(:name, :string)
    field(:description, :string)
    field(:color, :string)
    field(:icon, :string)
    field(:status, :string)
    field(:card_count, :integer)
    field(:chunk_count, :integer)
    field(:xp, :integer)

    timestamps(type: :utc_datetime_usec)
  end

  @required [:name]
  @optional [
    :tenant_id,
    :user_id,
    :description,
    :color,
    :icon,
    :status,
    :card_count,
    :chunk_count,
    :xp
  ]

  def changeset(track, attrs) do
    track
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, ~w(active paused archived),
      message: "must be active, paused, or archived"
    )
    |> default_status()
    |> default_counts()
  end

  defp default_status(changeset) do
    case get_field(changeset, :status) do
      nil -> put_change(changeset, :status, "active")
      _ -> changeset
    end
  end

  defp default_counts(changeset) do
    changeset
    |> put_default(:card_count, 0)
    |> put_default(:chunk_count, 0)
    |> put_default(:xp, 0)
    |> put_default(:color, "#4a90d9")
    |> put_default(:icon, "book")
  end

  defp put_default(changeset, key, default) do
    case get_field(changeset, key) do
      nil -> put_change(changeset, key, default)
      _ -> changeset
    end
  end
end
