defmodule BotArmyTerrain.TrackStore do
  @moduledoc """
  Track management: create, list, get by id, update status.
  Used by ingestion (create track from CSV deck name) and by Dungeon (list tracks for overworld).
  """

  use GenServer
  require Logger
  import Ecto.Query

  alias BotArmyTerrain.Repo
  alias BotArmyTerrain.Schemas.Track

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "List all tracks (optionally filter by status)."
  def list_tracks(opts \\ []) do
    status = Keyword.get(opts, :status)
    query = from(t in Track, order_by: [asc: t.name])
    query = if status, do: from(t in query, where: t.status == ^status), else: query
    Repo.all(query)
  end

  @doc "Get a track by id."
  def get_track(id), do: Repo.get(Track, id)

  @doc "Create or get track by name (idempotent for ingestion). Returns {:ok, track} or {:error, changeset}."
  def create_track(attrs) do
    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put_new("tenant_id", BotArmyCore.Tenant.default_tenant_id())

    %Track{}
    |> Track.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Find track by name (for CSV import: create track if not exists)."
  def get_or_create_track_by_name(name, opts \\ []) do
    name = to_string(name) |> String.trim()

    case Repo.get_by(Track, name: name) do
      nil ->
        attrs = [name: name] ++ Keyword.take(opts, [:description, :color, :icon])
        create_track(attrs)

      track ->
        {:ok, track}
    end
  end

  @doc "Increment chunk_count for a track (after ingesting chunks)."
  def increment_chunk_count(track_id, delta \\ 1) do
    case Repo.get(Track, track_id) do
      nil ->
        :error

      track ->
        new_count = (track.chunk_count || 0) + delta
        track |> Ecto.Changeset.change(chunk_count: new_count) |> Repo.update()
    end
  end

  @doc "Set track chunk_count from actual ContentChunk count (after ingest)."
  def update_chunk_count_from_store(track_id) do
    alias BotArmyTerrain.Schemas.ContentChunk

    count =
      from(c in ContentChunk, where: c.track_id == ^track_id, select: count(c.id)) |> Repo.one()

    case Repo.get(Track, track_id) do
      nil -> :error
      track -> track |> Ecto.Changeset.change(chunk_count: count) |> Repo.update()
    end
  end

  @doc "Set track card_count from actual Card count (after ingestion or generation), scoped to tenant."
  def update_card_count_from_store(tenant_id, track_id) do
    alias BotArmyTerrain.Schemas.Card

    count =
      from(c in Card,
        where: c.tenant_id == ^tenant_id and c.track_id == ^track_id,
        select: count(c.id)
      )
      |> Repo.one()

    case Repo.get(Track, track_id) do
      nil ->
        :error

      track ->
        if track.tenant_id == tenant_id do
          track |> Ecto.Changeset.change(card_count: count) |> Repo.update()
        else
          :error
        end
    end
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end
end
