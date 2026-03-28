defmodule BotArmyTerrain.GameGenerationWorker do
  @moduledoc """
  Worker that queues and processes game generation requests asynchronously.
  Follows fire-and-forget pattern: publishes LLM prompts and tracks state.

  Handles queue of track_ids waiting to generate game + dojo content.
  Processes one at a time with retry logic (max 2 retries).
  """

  use GenServer
  require Logger

  alias BotArmyTerrain.TrackStore
  alias BotArmyTerrain.LessonStore
  alias BotArmyTerrain.GameStateStore
  alias BotArmyTerrain.Handlers.GameGenerationHandler
  alias BotArmyRuntime.NATS.Connection

  @reconnect_delay_ms 5000
  @process_delay_ms 1000
  @idle_delay_ms 5000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Queue a track for game generation (fire-and-forget)."
  def queue_generation(track_id) do
    GenServer.cast(__MODULE__, {:generate, track_id})
  end

  @impl true
  def init(_opts) do
    state = %{
      queue: [],        # [{track_id, retry_count}, ...]
      processing: false
    }

    Process.send_after(self(), :process_next, @process_delay_ms)
    {:ok, state}
  end

  @impl true
  def handle_cast({:generate, track_id}, state) do
    if Enum.any?(state.queue, fn {id, _} -> id == track_id end) do
      Logger.warning("Terrain: track #{track_id} already queued for generation")
      {:noreply, state}
    else
      new_queue = state.queue ++ [{track_id, 0}]
      {:noreply, %{state | queue: new_queue}}
    end
  end

  @impl true
  def handle_info(:process_next, state) do
    case state.queue do
      [] ->
        Process.send_after(self(), :process_next, @idle_delay_ms)
        {:noreply, state}

      [{track_id, retries} | rest] ->
        result = generate_track(track_id)

        case result do
          :ok ->
            Logger.info("Terrain: game generation queued for track #{track_id}")
            Process.send_after(self(), :process_next, @process_delay_ms)
            {:noreply, %{state | queue: rest}}

          {:error, _reason} ->
            if retries < 2 do
              Logger.warning("Terrain: retrying game generation for track #{track_id} (attempt #{retries + 2}/3)")
              new_queue = rest ++ [{track_id, retries + 1}]
              Process.send_after(self(), :process_next, @reconnect_delay_ms)
              {:noreply, %{state | queue: new_queue}}
            else
              Logger.error("Terrain: game generation failed for track #{track_id} after 3 attempts")
              emit_event("terrain.game.generation.failed", %{"track_id" => track_id, "phase" => "game"})
              Process.send_after(self(), :process_next, @process_delay_ms)
              {:noreply, %{state | queue: rest}}
            end
        end
    end
  end

  defp generate_track(track_id) do
    with {:ok, track} <- get_track(track_id),
         {:ok, lessons} <- get_lessons(track_id) do
      unless Enum.empty?(lessons) do
        GameStateStore.mark_status(track_id, "generating_game")
        emit_event("terrain.game.generation.started", %{"track_id" => track_id})

        GameGenerationHandler.generate_game(track_id, lessons)
      end

      :ok
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_track(track_id) do
    case TrackStore.get_track(track_id) do
      nil -> {:error, "track not found"}
      track -> {:ok, track}
    end
  end

  defp get_lessons(track_id) do
    lessons = LessonStore.list_lessons_by_track(track_id)
    {:ok, lessons}
  end

  defp emit_event(event_name, payload) do
    case Connection.get_connection() do
      {:ok, conn} ->
        envelope = %{
          "event" => event_name,
          "event_id" => Elixir.UUID.uuid4(),
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "source" => "bot_army_terrain",
          "source_node" => :inet.gethostname() |> elem(1) |> to_string(),
          "schema_version" => "1.0",
          "payload" => payload
        }

        Gnat.pub(conn, "events.#{event_name}", Jason.encode!(envelope))

      {:error, _} ->
        Logger.warning("Terrain: NATS unavailable, skipping event #{event_name}")
    end
  end
end
