defmodule BotArmyTerrain.Ingestion.YamlImporter do
  @moduledoc """
  Imports track + chunks from a YAML file. Each file = one track.

  YAML format:
    name: "Track Name"
    description: "Optional description"
    color: "#4a90d9"
    icon: "book"
    chunks:
      - title: "Chunk Title"
        content: "Chunk content..."
        tags: [tag1, tag2]
  """

  require Logger

  alias BotArmyTerrain.TrackStore
  alias BotArmyTerrain.ChunkStore
  alias BotArmyTerrain.EmbedWorker

  @doc """
  Imports a single track + chunks from a YAML file at path.
  Returns {:ok, %{track: name, track_id: id, chunks_imported: n, chunks_updated: n}}
  or {:error, reason}
  """
  def import_file(path) do
    with {:ok, data} <- YamlElixir.read_from_file(path),
         {:ok, track} <- validate_and_create_track(data),
         {:ok, counts} <- import_chunks(track, Map.get(data, "chunks", [])) do
      Logger.info("Terrain: imported YAML #{path} -> track #{track.name}, #{counts.imported} new, #{counts.updated} updated")
      {:ok, %{
        track: track.name,
        track_id: track.id,
        chunks_imported: counts.imported,
        chunks_updated: counts.updated
      }}
    else
      {:error, reason} ->
        Logger.error("Terrain: YAML import failed #{path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp validate_and_create_track(data) do
    case Map.get(data, "name") do
      nil ->
        {:error, "YAML missing required 'name' field"}

      name ->
        name = to_string(name) |> String.trim()
        description = Map.get(data, "description", "") |> to_string()
        color = Map.get(data, "color")
        icon = Map.get(data, "icon")

        opts = []
        opts = if description != "", do: [description: description] ++ opts, else: opts
        opts = if color, do: [color: to_string(color)] ++ opts, else: opts
        opts = if icon, do: [icon: to_string(icon)] ++ opts, else: opts

        case TrackStore.get_or_create_track_by_name(name, opts) do
          {:ok, track} -> {:ok, track}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp import_chunks(track, chunks_data) when is_list(chunks_data) do
    {imported_count, updated_count} =
      Enum.reduce(chunks_data, {0, 0}, fn chunk_data, {imported, updated} ->
        case import_single_chunk(track, chunk_data) do
          :imported -> {imported + 1, updated}
          :updated -> {imported, updated + 1}
          :skip -> {imported, updated}
        end
      end)

    # Update track chunk count after all chunks imported
    TrackStore.update_chunk_count_from_store(track.id)

    {:ok, %{imported: imported_count, updated: updated_count}}
  end

  defp import_chunks(_track, _chunks_data) do
    {:error, "YAML 'chunks' must be a list"}
  end

  defp import_single_chunk(track, chunk_data) when is_map(chunk_data) do
    title = Map.get(chunk_data, "title", "") |> to_string() |> String.trim()
    content = Map.get(chunk_data, "content", "") |> to_string() |> String.trim()

    if title == "" or content == "" do
      Logger.warning("Skipping chunk with missing title or content")
      :skip
    else
      tags = Map.get(chunk_data, "tags", [])
      tags = if is_list(tags), do: tags, else: []

      # Build combined content (title + "\n\n" + content) and hash it
      combined_content = title <> "\n\n" <> content
      content_hash = :crypto.hash(:sha256, combined_content) |> Base.encode16(case: :lower)

      # Check if chunk already exists
      existing = Ecto.Adapters.SQL.query!(
        BotArmyTerrain.Repo,
        "SELECT id FROM terrain.content_chunks WHERE track_id = $1 AND content_hash = $2 LIMIT 1",
        [track.id, content_hash]
      )

      attrs = %{
        track_id: track.id,
        source_type: "yaml",
        source_path: "yaml_import",
        content: combined_content,
        content_hash: content_hash,
        metadata: %{"title" => title, "tags" => tags}
      }

      case ChunkStore.upsert_chunk(attrs) do
        {:ok, chunk} ->
          # Queue embedding only for new chunks
          if Enum.empty?(existing.rows) do
            EmbedWorker.queue_chunk(chunk.id)
            :imported
          else
            :updated
          end

        {:error, reason} ->
          Logger.warning("Failed to upsert chunk: #{inspect(reason)}")
          :skip
      end
    end
  end

  defp import_single_chunk(_track, _chunk_data) do
    Logger.warning("Chunk data must be a map")
    :skip
  end
end
