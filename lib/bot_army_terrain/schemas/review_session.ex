defmodule BotArmyTerrain.Schemas.ReviewSession do
  @moduledoc """
  Review session schema tracking full learning sessions from start to end.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @schema_prefix "terrain"
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "review_sessions" do
    field :track_id, :binary_id
    field :state, :string, default: "active"
    field :cards_reviewed, :integer, default: 0
    field :cards_correct, :integer, default: 0
    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @required [:track_id, :started_at]
  @optional [:state, :cards_reviewed, :cards_correct, :ended_at]

  def changeset(session, attrs) do
    session
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:state, ~w(active complete), message: "must be active or complete")
  end
end
