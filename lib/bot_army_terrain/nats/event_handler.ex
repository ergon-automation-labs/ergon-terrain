defmodule BotArmyTerrain.NATS.EventHandler do
  @moduledoc """
  Event handler for LLM responses and embeddings.

  Subscribes to:
  - events.llm.response.parsed
  - events.llm.embedding.created
  - events.llm.completion.terrain.lesson_generation
  - events.llm.completion.terrain.game_generation

  Routes to appropriate handlers for processing.
  """

  use GenServer
  require Logger

  @reconnect_delay_ms 5000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    state = %{subscriptions: [], opts: opts}
    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case get_connection() do
      {:ok, conn} -> subscribe(conn, state)
      {:error, _} -> schedule_reconnect(state)
    end
  end

  @impl true
  def handle_info({:msg, %{topic: topic, body: body}}, state) do
    Logger.debug("[TerrainEventHandler] Received: #{topic}")

    case decode(body) do
      {:ok, msg} -> handle_event(topic, msg)
      {:error, reason} -> Logger.warning("[TerrainEventHandler] Decode failed: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:connect_retry, state) do
    {:noreply, state, {:continue, :connect}}
  end

  defp get_connection do
    try do
      GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 5000)
    rescue
      _ -> {:error, :unavailable}
    catch
      :exit, _ -> {:error, :unavailable}
    end
  end

  defp subscribe(conn, state) do
    subjects = [
      "events.llm.response.parsed",
      "events.llm.embedding.created",
      "events.llm.completion.terrain.lesson_generation",
      "events.llm.completion.terrain.game_generation"
    ]

    subs =
      Enum.map(subjects, fn subject ->
        case Gnat.sub(conn, self(), subject) do
          {:ok, sub} ->
            Logger.info("[TerrainEventHandler] Subscribed to #{subject}")
            sub

          {:error, reason} ->
            Logger.error("[TerrainEventHandler] Subscribe failed for #{subject}: #{inspect(reason)}")
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    if length(subs) > 0 do
      {:noreply, %{state | subscriptions: subs}}
    else
      Logger.error("[TerrainEventHandler] Failed to subscribe to any subjects")
      schedule_reconnect(state)
    end
  end

  defp schedule_reconnect(state) do
    Process.send_after(self(), :connect_retry, @reconnect_delay_ms)
    {:noreply, state}
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, map} -> {:ok, map}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp handle_event("events.llm.response.parsed", msg) do
    BotArmyTerrain.Handlers.LlmResponseHandler.handle_parsed(msg)
  end

  defp handle_event("events.llm.embedding.created", msg) do
    payload = msg["payload"] || %{}

    cond do
      payload["lesson_id"] ->
        BotArmyTerrain.Handlers.LessonEmbeddingHandler.handle_embedding(msg)

      payload["card_id"] ->
        BotArmyTerrain.Handlers.CardEmbeddingHandler.handle_embedding(msg)

      payload["chunk_id"] ->
        embedding = payload["embedding"]
        chunk_id = payload["chunk_id"]

        case BotArmyTerrain.ChunkStore.update_embedding(chunk_id, embedding) do
          {:ok, _chunk} ->
            Logger.debug("[TerrainEventHandler] Updated embedding for chunk #{chunk_id}")

          {:error, reason} ->
            Logger.warning(
              "[TerrainEventHandler] Failed to update embedding for chunk #{chunk_id}: #{inspect(reason)}"
            )
        end

      true ->
        Logger.warning("[TerrainEventHandler] Unknown embedding type in payload")
    end
  end

  defp handle_event("events.llm.completion.terrain.lesson_generation", msg) do
    BotArmyTerrain.Handlers.LessonCompletionHandler.handle_completion(msg)
  end

  defp handle_event("events.llm.completion.terrain.game_generation", msg) do
    BotArmyTerrain.Handlers.GameCompletionHandler.handle_completion(msg)
  end

  defp handle_event(_topic, _msg) do
    :ok
  end
end
