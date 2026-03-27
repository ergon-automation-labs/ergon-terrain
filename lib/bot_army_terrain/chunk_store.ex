defmodule BotArmyTerrain.ChunkStore do
  @moduledoc """
  Persistence for content chunks. Idempotent upsert by (track_id, content_hash):
  on re-import, update metadata but skip re-embedding if hash matches.
  """

  use GenServer
  require Logger
  import Ecto.Query

  alias BotArmyTerrain.Repo
  alias BotArmyTerrain.Schemas.ContentChunk

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Upsert a chunk. If (track_id, content_hash) exists, update metadata only and return existing.
  Otherwise insert. Embedding can be nil (filled later by EmbeddingClient).
  """
  def upsert_chunk(attrs) do
    track_id = attrs[:track_id] || attrs["track_id"]
    content_hash = attrs[:content_hash] || attrs["content_hash"]
    existing = Repo.get_by(ContentChunk, track_id: track_id, content_hash: content_hash)

    if existing do
      existing
      |> Ecto.Changeset.change(metadata: attrs[:metadata] || attrs["metadata"] || existing.metadata)
      |> Repo.update()
    else
      %ContentChunk{}
      |> ContentChunk.changeset(attrs)
      |> Repo.insert()
    end
  end

  @doc "List chunks for a track (for embedding or export)."
  def list_by_track(track_id) do
    from(c in ContentChunk, where: c.track_id == ^track_id, order_by: [asc: c.inserted_at])
    |> Repo.all()
  end

  @doc "Get chunk by id."
  def get(id), do: Repo.get(ContentChunk, id)

  @doc "Update chunk embedding vector after generation."
  def update_embedding(chunk_id, embedding_vector) do
    case Repo.get(ContentChunk, chunk_id) do
      nil ->
        {:error, :not_found}

      chunk ->
        chunk
        |> Ecto.Changeset.change(
          embedding_vector: embedding_vector,
          embedded_at: DateTime.utc_now()
        )
        |> Repo.update()
    end
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end
end
