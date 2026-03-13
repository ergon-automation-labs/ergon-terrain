defmodule BotArmyTerrain.Ingestion.IngestionWorker do
  @moduledoc """
  Orchestrates ingestion: parse (CSV/markdown) → create track → store chunks.
  Re-import preserves existing chunks (upsert by content_hash); does not overwrite
  any state that belongs to Learning Bot (cards live there).
  """

  use GenServer
  require Logger

  alias BotArmyTerrain.Ingestion.CsvParser
  alias BotArmyTerrain.TrackStore
  alias BotArmyTerrain.ChunkStore
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Ingest a flashcard CSV file. Creates track from 'track' column, one chunk per row (content = front + back; content_hash from front for idempotency)."
  def ingest_csv(path) do
    GenServer.call(__MODULE__, {:ingest_csv, path}, 60_000)
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:ingest_csv, path}, _from, state) do
    result = do_ingest_csv(path)
    {:reply, result, state}
  end

  defp do_ingest_csv(path) do
    case CsvParser.parse_path(path) do
      {:ok, []} ->
        Logger.info("Terrain: CSV empty or header-only #{path}")
        {:ok, %{tracks: 0, chunks: 0}}

      {:ok, rows} ->
        # Determine track name from first row (or "Default")
        track_name = get_track_name(rows)
        {:ok, track} = TrackStore.get_or_create_track_by_name(track_name)

        for row <- rows do
          front = Map.get(row, "front", "") |> to_string()
          back = Map.get(row, "back", "") |> to_string()
          tags = Map.get(row, "tags", "") |> to_string()
          content = front <> "\n\n" <> back
          content_hash = content_hash_front(front)

          attrs = %{
            track_id: track.id,
            source_type: "csv",
            source_path: path,
            content: content,
            content_hash: content_hash,
            metadata: %{"front" => front, "back" => back, "tags" => tags}
          }

          case ChunkStore.upsert_chunk(attrs) do
            {:ok, _} -> :ok
            _ -> :skip
          end
        end
        chunks_processed = length(rows)

        # Keep track chunk_count in sync (total chunks for this track)
        BotArmyTerrain.TrackStore.update_chunk_count_from_store(track.id)

        Logger.info("Terrain: ingested CSV #{path} -> track #{track_name}, #{chunks_processed} rows")
        {:ok, %{tracks: 1, chunks: chunks_processed}}

      {:error, reason} ->
        Logger.error("Terrain: CSV ingest failed #{path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp get_track_name(rows) do
    case rows do
      [first | _] -> Map.get(first, "track", "Default") |> to_string() |> String.trim()
      _ -> "Default"
    end
  end

  defp content_hash_front(front) do
    :crypto.hash(:sha256, to_string(front)) |> Base.encode16(case: :lower)
  end
end
