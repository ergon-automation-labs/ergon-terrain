defmodule BotArmyTerrain.Application do
  @moduledoc """
  Terrain application supervisor.

  Manages:
  - Repo (tracks, content_chunks with pgvector)
  - TrackStore, ChunkStore
  - IngestionWorker (CSV/markdown → chunks/tracks)
  - NATS consumer (bot.army.terrain.command.ingest, etc.)
  """

  use Application

  @env Mix.env()

  @impl true
  def start(_type, _args) do
    children = []
    |> maybe_add_repo()
    |> maybe_add_track_store()
    |> maybe_add_chunk_store()
    |> maybe_add_card_store()
    |> maybe_add_ingestion_worker()
    |> maybe_add_consumer()
    |> maybe_add_request_handler()

    opts = [strategy: :one_for_one, name: BotArmyTerrain.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_add_repo(children) do
    if @env == :test, do: children, else: [BotArmyTerrain.Repo | children]
  end

  defp maybe_add_track_store(children) do
    if @env == :test, do: children, else: [{BotArmyTerrain.TrackStore, []} | children]
  end

  defp maybe_add_chunk_store(children) do
    if @env == :test, do: children, else: [{BotArmyTerrain.ChunkStore, []} | children]
  end

  defp maybe_add_card_store(children) do
    if @env == :test, do: children, else: [{BotArmyTerrain.CardStore, []} | children]
  end

  defp maybe_add_ingestion_worker(children) do
    if @env == :test, do: children, else: [{BotArmyTerrain.Ingestion.IngestionWorker, []} | children]
  end

  defp maybe_add_consumer(children) do
    if @env == :test, do: children, else: [{BotArmyTerrain.NATS.Consumer, []} | children]
  end

  defp maybe_add_request_handler(children) do
    if @env == :test, do: children, else: [{BotArmyTerrain.NATS.RequestHandler, []} | children]
  end
end
