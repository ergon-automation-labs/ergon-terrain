defmodule BotArmyTerrain.GraphMigrations.V002SyncTracks do
  @moduledoc """
  Migration V002: Sync Track nodes from relational DB to graph.

  Reads all tracks from BotArmyTerrain.Repo and upserts them as
  Track nodes in the knowledge graph.
  """

  require Logger

  @version 2
  @description "Sync Track nodes from relational database"

  def version, do: @version
  def description, do: @description

  def up do
    Logger.info("[Migration V002] Syncing tracks to graph...")

    tracks = fetch_all_tracks()
    Logger.info("[Migration V002] Found #{Enum.count(tracks)} tracks")

    upsert_track_nodes(tracks)

    Logger.info("[Migration V002] Synced #{Enum.count(tracks)} track nodes to graph")
    :ok
  end

  defp fetch_all_tracks do
    BotArmyTerrain.Repo.all(BotArmyTerrain.Track)
  rescue
    e ->
      Logger.error("[Migration V002] Failed to fetch tracks", error: inspect(e))
      []
  end

  defp upsert_track_nodes(tracks) do
    nodes =
      Enum.map(tracks, fn track ->
        %{
          id: UUID.binary_to_string!(track.id),
          type: "Track",
          name: track.name,
          properties: %{
            description: track.description,
            status: track.status,
            xp: track.xp,
            icon: track.icon,
            color: track.color,
            card_count: track.card_count,
            chunk_count: track.chunk_count
          }
        }
      end)

    case BotArmy.Graph.upsert_nodes(nodes) do
      {:ok, count} ->
        Logger.info("[Migration V002] Upserted #{count} track nodes")
        :ok

      {:error, e} ->
        Logger.error("[Migration V002] Failed to upsert track nodes", error: inspect(e))
        raise "Could not upsert track nodes: #{inspect(e)}"
    end
  end
end
