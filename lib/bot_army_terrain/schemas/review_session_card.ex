defmodule BotArmyTerrain.Schemas.ReviewSessionCard do
  @moduledoc """
  Individual card review record within a review session.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @schema_prefix "terrain"
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "review_session_cards" do
    field :session_id, :binary_id
    field :card_id, :binary_id
    field :quality, :integer
    field :elapsed_ms, :integer
    field :reviewed_at, :utc_datetime_usec
  end

  @required [:session_id, :quality, :elapsed_ms, :reviewed_at]
  @optional [:card_id]

  def changeset(record, attrs) do
    record
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:quality, 0..5, message: "must be 0-5")
  end
end
