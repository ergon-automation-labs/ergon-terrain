defmodule BotArmyTerrain.Schemas.ContentChunk do
  @moduledoc """
  Atomic unit of ingested knowledge. Every chunk is embedded and stored (pgvector).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @schema_prefix "terrain"
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "content_chunks" do
    field(:tenant_id, :binary_id)
    field(:user_id, :binary_id)
    field(:source_type, :string)
    field(:source_path, :string)
    field(:content, :string)
    field(:content_hash, :string)
    field(:metadata, :map)
    field(:embedding_vector, Pgvector.Ecto.Vector)
    field(:embedded_at, :utc_datetime_usec)

    belongs_to(:track, BotArmyTerrain.Schemas.Track)

    timestamps(type: :utc_datetime_usec)
  end

  @required [:source_type, :source_path, :track_id, :content, :content_hash]
  @optional [:tenant_id, :user_id, :metadata, :embedding_vector, :embedded_at]

  def changeset(chunk, attrs) do
    chunk
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:source_type, ~w(notion obsidian markdown csv manual))
    |> foreign_key_constraint(:track_id)
  end
end
