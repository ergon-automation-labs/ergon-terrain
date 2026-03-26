defmodule BotArmyTerrain.Schemas.Lesson do
  use Ecto.Schema
  import Ecto.Changeset

  @schema_prefix "terrain"
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "lessons" do
    field :chunk_id, :binary_id
    field :title, :string
    field :explanation, :string
    field :external_link, :string, default: ""
    field :difficulty, :integer, default: 1
    field :embedding_vector, Pgvector.Ecto.Vector
    field :embedded_at, :utc_datetime_usec
    field :generated_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(lesson, attrs) do
    lesson
    |> cast(attrs, [:chunk_id, :title, :explanation, :external_link, :difficulty, :embedding_vector, :embedded_at, :generated_at])
    |> validate_required([:chunk_id, :title, :explanation, :generated_at])
    |> unique_constraint(:chunk_id)
  end
end
