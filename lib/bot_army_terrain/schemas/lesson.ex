defmodule BotArmyTerrain.Schemas.Lesson do
  use Ecto.Schema
  import Ecto.Changeset

  @schema_prefix "terrain"
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "lessons" do
    field(:tenant_id, :binary_id)
    field(:user_id, :binary_id)
    field(:chunk_id, :binary_id)
    field(:track_id, :binary_id)
    field(:title, :string)
    field(:explanation, :string)
    field(:external_link, :string, default: "")
    field(:difficulty, :integer, default: 1)
    field(:embedding_vector, Pgvector.Ecto.Vector)
    field(:embedded_at, :utc_datetime_usec)
    field(:generated_at, :utc_datetime_usec)
    field(:quiz_question, :string)
    field(:quiz_options, {:array, :string})
    field(:quiz_correct_index, :integer)
    field(:quiz_questions, {:array, :map}, default: [])
    field(:host_intro, :string)
    field(:host_correct, :string)
    field(:host_wrong, :string)
    field(:npc_players, :map)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(lesson, attrs) do
    lesson
    |> cast(attrs, [
      :chunk_id,
      :track_id,
      :title,
      :explanation,
      :external_link,
      :difficulty,
      :embedding_vector,
      :embedded_at,
      :generated_at,
      :quiz_question,
      :quiz_options,
      :quiz_correct_index,
      :quiz_questions,
      :host_intro,
      :host_correct,
      :host_wrong,
      :npc_players,
      :tenant_id,
      :user_id
    ])
    |> validate_required([:chunk_id, :title, :explanation, :generated_at])
    |> unique_constraint(:chunk_id)
  end
end
