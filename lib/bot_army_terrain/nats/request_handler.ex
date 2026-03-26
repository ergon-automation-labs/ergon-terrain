defmodule BotArmyTerrain.NATS.RequestHandler do
  @moduledoc """
  NATS request/reply handler for terrain surface queries.

  Handles:
  - terrain.tracks.list → {tracks: [...]}
  - terrain.cards.due → {cards: [...]}
  - terrain.review.submit → fire-and-forget
  - terrain.lesson.generation.request → {queued: true}
  """

  use GenServer
  require Logger

  alias BotArmyTerrain.{TrackStore, CardStore, Handlers.SessionHandler}

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
  def handle_info({:msg, %{topic: topic, body: body, reply_to: reply_to}}, state) do
    Logger.debug("Terrain RequestHandler: #{topic}")

    case decode(body) do
      {:ok, msg} ->
        response = handle_request(topic, msg)
        send_reply(state, reply_to, response)

      {:error, reason} ->
        Logger.warning("Terrain decode failed: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:msg, %{topic: topic, body: body}}, state) do
    Logger.debug("Terrain RequestHandler (no reply): #{topic}")

    case decode(body) do
      {:ok, msg} -> handle_event(topic, msg)
      {:error, reason} -> Logger.warning("Terrain decode failed: #{inspect(reason)}")
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
    subscriptions = [
      "terrain.tracks.list",
      "terrain.cards.due",
      "terrain.review.submit",
      "terrain.session.start",
      "terrain.session.end",
      "terrain.session.stats",
      "terrain.cards.similar",
      "terrain.lesson.generation.request",
      "terrain.lesson.get",
      "terrain.lesson.list"
    ]

    results =
      Enum.map(subscriptions, fn subject ->
        case Gnat.sub(conn, self(), subject) do
          {:ok, sub} ->
            Logger.info("Terrain subscribed to #{subject}")
            sub

          {:error, reason} ->
            Logger.error("Terrain subscribe to #{subject} failed: #{inspect(reason)}")
            nil
        end
      end)

    if Enum.all?(results, &(&1 != nil)) do
      {:noreply, %{state | subscriptions: results}}
    else
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

  defp handle_request("terrain.tracks.list", _msg) do
    tracks = TrackStore.list_tracks(status: "active")

    track_list =
      Enum.map(tracks, fn track ->
        cards_due = CardStore.count_due_cards(track.id)

        %{
          "id" => track.id,
          "name" => track.name,
          "card_count" => track.card_count || 0,
          "cards_due" => cards_due || 0,
          "status" => track.status,
          "last_reviewed_at" => track.updated_at && DateTime.to_iso8601(track.updated_at)
        }
      end)

    Jason.encode!(%{"tracks" => track_list})
  end

  defp handle_request("terrain.cards.due", msg) do
    track_id = msg["track_id"]

    if track_id do
      cards = CardStore.list_due_cards(track_id, limit: 20)

      card_list =
        Enum.map(cards, fn card ->
          %{
            "id" => card.id,
            "front" => card.front,
            "back" => card.back
          }
        end)

      Jason.encode!(%{"cards" => card_list})
    else
      Jason.encode!(%{"error" => "track_id required", "cards" => []})
    end
  end

  defp handle_request("terrain.session.start", msg) do
    SessionHandler.handle_start(msg)
  end

  defp handle_request("terrain.session.end", msg) do
    SessionHandler.handle_end(msg)
  end

  defp handle_request("terrain.session.stats", msg) do
    session_id = msg["session_id"]

    if session_id do
      store = Application.get_env(:bot_army_terrain, :review_session_store, BotArmyTerrain.ReviewSessionStore)

      case store.get_session_stats(session_id) do
        {:ok, stats} -> Jason.encode!(stats)
        {:error, reason} -> Jason.encode!(%{"error" => inspect(reason)})
      end
    else
      Jason.encode!(%{"error" => "session_id required"})
    end
  end

  defp handle_request("terrain.cards.similar", msg) do
    card_id = msg["card_id"]
    limit = msg["limit"] || 5

    if card_id do
      case CardStore.get_card(card_id) do
        nil ->
          Jason.encode!(%{"error" => "card not found", "cards" => []})

        card ->
          if card.embedding_vector do
            similar_cards = CardStore.find_similar_cards(card.track_id, card.embedding_vector, limit)

            card_list =
              Enum.map(similar_cards, fn result ->
                %{
                  "id" => result.id,
                  "front" => result.front,
                  "back" => result.back,
                  "similarity" => result.similarity
                }
              end)

            Jason.encode!(%{"cards" => card_list})
          else
            Jason.encode!(%{"error" => "card not embedded yet", "cards" => []})
          end
      end
    else
      Jason.encode!(%{"error" => "card_id required", "cards" => []})
    end
  end

  defp handle_request("terrain.lesson.generation.request", msg) do
    chunk_id = msg["chunk_id"]
    chunk_title = msg["chunk_title"] || ""
    chunk_content = msg["chunk_content"] || ""

    if chunk_id && chunk_title && chunk_content do
      # Queue for background generation
      BotArmyTerrain.LessonGenerationWorker.queue_lesson(chunk_id, chunk_title, chunk_content)

      Jason.encode!(%{
        "ok" => true,
        "queued" => true,
        "chunk_id" => chunk_id,
        "message" => "Lesson generation queued"
      })
    else
      Jason.encode!(%{
        "ok" => false,
        "error" => "chunk_id, chunk_title, and chunk_content required"
      })
    end
  end

  defp handle_request("terrain.lesson.get", msg) do
    chunk_id = msg["chunk_id"]

    case BotArmyTerrain.LessonStore.get_lesson_by_chunk(chunk_id) do
      nil ->
        Jason.encode!(%{
          "ok" => false,
          "error" => "lesson not found",
          "chunk_id" => chunk_id
        })

      lesson ->
        Jason.encode!(%{
          "ok" => true,
          "chunk_id" => lesson.chunk_id,
          "title" => lesson.title,
          "explanation" => lesson.explanation,
          "external_link" => lesson.external_link || "",
          "difficulty" => lesson.difficulty,
          "quiz_question" => lesson.quiz_question,
          "quiz_options" => lesson.quiz_options || [],
          "quiz_correct_index" => lesson.quiz_correct_index,
          "host_intro" => lesson.host_intro,
          "host_correct" => lesson.host_correct,
          "host_wrong" => lesson.host_wrong,
          "npc_players" => lesson.npc_players || [],
          "generated_at" => DateTime.to_iso8601(lesson.generated_at)
        })
    end
  end

  defp handle_request("terrain.lesson.list", _msg) do
    lessons = BotArmyTerrain.LessonStore.list_lessons()

    lesson_list =
      Enum.map(lessons, fn l ->
        %{
          "chunk_id" => l.chunk_id,
          "title" => l.title,
          "external_link" => l.external_link || "",
          "difficulty" => l.difficulty,
          "generated_at" => DateTime.to_iso8601(l.generated_at)
        }
      end)

    Jason.encode!(%{
      "ok" => true,
      "lessons" => lesson_list
    })
  end

  defp handle_request(topic, _msg) do
    Logger.warning("Unknown request topic: #{topic}")
    Jason.encode!(%{"error" => "unknown topic"})
  end

  defp handle_event("terrain.review.submit", msg) do
    case BotArmyTerrain.Handlers.ReviewHandler.handle_submit(msg) do
      :ok -> :ok
      {:error, reason} -> Logger.error("Review submit failed: #{inspect(reason)}")
    end
  end

  defp send_reply(_state, reply_to, response) do
    case get_connection() do
      {:ok, conn} ->
        case Gnat.pub(conn, reply_to, response) do
          :ok -> :ok
          {:error, reason} -> Logger.error("Failed to send reply: #{inspect(reason)}")
        end

      {:error, _} ->
        Logger.error("Cannot send reply: NATS disconnected")
    end
  end
end
