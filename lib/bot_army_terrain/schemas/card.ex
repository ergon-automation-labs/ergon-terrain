defmodule BotArmyTerrain.Schemas.Card do
  @moduledoc """
  Flashcard schema with SRS (spaced repetition scheduling) fields.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @schema_prefix "terrain"
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "cards" do
    field :track_id, :binary_id
    field :chunk_id, :binary_id
    field :front, :string
    field :back, :string
    field :card_type, :string, default: "basic"
    field :generation_model, :string

    field :ease_factor, :float, default: 2.5
    field :interval_days, :integer, default: 1
    field :repetitions, :integer, default: 0
    field :next_review_at, :utc_datetime_usec
    field :last_reviewed_at, :utc_datetime_usec
    field :state, :string, default: "new"

    field :embedding_vector, Pgvector.Ecto.Vector
    field :embedded_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @required [:track_id, :front, :back]
  @optional [:chunk_id, :card_type, :generation_model, :ease_factor, :interval_days, :repetitions, :next_review_at, :last_reviewed_at, :state, :embedding_vector, :embedded_at]

  def changeset(card, attrs) do
    card
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:card_type, ~w(basic cloze definition), message: "must be basic, cloze, or definition")
    |> validate_inclusion(:state, ~w(new learning review suspended), message: "must be new, learning, review, or suspended")
    |> set_next_review_at()
  end

  defp set_next_review_at(changeset) do
    case get_field(changeset, :next_review_at) do
      nil -> put_change(changeset, :next_review_at, DateTime.utc_now())
      _ -> changeset
    end
  end
end
