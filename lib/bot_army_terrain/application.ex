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
    children =
      []
      |> maybe_add_repo()
      |> maybe_add_track_store()
      |> maybe_add_chunk_store()
      |> maybe_add_card_store()
      |> maybe_add_review_session_store()
      |> maybe_add_embed_worker()
      |> maybe_add_ingestion_worker()
      |> maybe_add_lesson_generation_worker()
      |> maybe_add_lesson_store()
      |> maybe_add_lesson_embed_worker()
      |> maybe_add_game_state_store()
      |> maybe_add_game_generation_worker()
      |> maybe_add_pulse_publisher()
      |> maybe_add_outcome_tracker()
      |> add_nats_children(@env)

    opts = [strategy: :one_for_one, name: BotArmyTerrain.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_add_repo(children) do
    if @env == :test do
      children
    else
      [
        BotArmyTerrain.Repo,
        {BotArmyTerrain.GraphRepo, restart: :temporary}
        | children
      ]
    end
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

  defp maybe_add_review_session_store(children) do
    if @env == :test, do: children, else: [{BotArmyTerrain.ReviewSessionStore, []} | children]
  end

  defp maybe_add_embed_worker(children) do
    if @env == :test, do: children, else: [{BotArmyTerrain.EmbedWorker, []} | children]
  end

  defp maybe_add_ingestion_worker(children) do
    if @env == :test,
      do: children,
      else: [{BotArmyTerrain.Ingestion.IngestionWorker, []} | children]
  end

  defp maybe_add_lesson_generation_worker(children) do
    if @env == :test, do: children, else: [{BotArmyTerrain.LessonGenerationWorker, []} | children]
  end

  defp maybe_add_lesson_store(children) do
    if @env == :test, do: children, else: [{BotArmyTerrain.LessonStore, []} | children]
  end

  defp maybe_add_lesson_embed_worker(children) do
    if @env == :test, do: children, else: [{BotArmyTerrain.LessonEmbedWorker, []} | children]
  end

  defp maybe_add_game_state_store(children) do
    if @env == :test, do: children, else: [{BotArmyTerrain.GameStateStore, []} | children]
  end

  defp maybe_add_game_generation_worker(children) do
    if @env == :test, do: children, else: [{BotArmyTerrain.GameGenerationWorker, []} | children]
  end

  defp maybe_add_pulse_publisher(children) do
    if @env == :test, do: children, else: [{BotArmyTerrain.PulsePublisher, []} | children]
  end

  # The three processes that hold subscriptions. They are named in one function because the
  # Consumer was *missing from this list*: it existed, it had command handlers, it had a
  # subject list, and nothing ever started it — so on the host every
  # `bot.army.terrain.command.*` publish (ingest, import_cards, generate_cards) was delivered
  # to no subscriber and dropped, with no log line anywhere, because a publish to a subject
  # nobody holds is not an error. Measured 2026-10-26: `/subsz` on mini showed the sixteen
  # RequestHandler subjects and not one command subject. It is public and takes the env so a
  # test can assert the consumer is supervised without booting a broker.
  @doc "Broker-facing children for a given environment."
  def nats_children(:test), do: []

  def nats_children(_env) do
    [
      {BotArmyTerrain.NATS.Consumer, []},
      {BotArmyTerrain.NATS.RequestHandler, []},
      {BotArmyTerrain.NATS.EventHandler, []}
    ]
  end

  defp add_nats_children(children, env), do: children ++ nats_children(env)

  defp maybe_add_outcome_tracker(children) do
    if @env == :test,
      do: children,
      else: [
        {BotArmyLibraryLearning.OutcomeTracker,
         [repo: BotArmyTerrain.Repo, name: :terrain_outcome_tracker]}
        | children
      ]
  end
end
