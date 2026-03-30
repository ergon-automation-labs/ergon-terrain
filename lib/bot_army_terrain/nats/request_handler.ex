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
      "terrain.tracks.import",
      "terrain.track.import",
      "terrain.cards.due",
      "terrain.review.submit",
      "terrain.session.start",
      "terrain.session.end",
      "terrain.session.stats",
      "terrain.cards.similar",
      "terrain.lesson.generation.request",
      "terrain.lesson.get",
      "terrain.lesson.list",
      "terrain.game.generate",
      "terrain.game.status",
      "terrain.game.get"
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

    Jason.encode!(%{"ok" => true, "tracks" => track_list})
  end

  defp handle_request("terrain.tracks.import", msg) do
    path = msg["path"]
    resolved_path = resolve_import_path(path)

    cond do
      is_nil(path) ->
        Jason.encode!(%{"ok" => false, "error" => "path required"})

      not File.exists?(resolved_path) ->
        Jason.encode!(%{
          "ok" => false,
          "error" => "file not found: #{resolved_path}",
          "requested_path" => path
        })

      File.dir?(resolved_path) ->
        case BotArmyTerrain.Ingestion.LessonDirectoryImporter.import_directory(resolved_path) do
          {:ok, result} ->
            Jason.encode!(%{
              "ok" => true,
              "tracks_imported" => result.tracks_imported,
              "lessons_imported" => result.lessons_imported,
              "requested_path" => path,
              "resolved_path" => resolved_path
            })

          {:error, reason} ->
            Jason.encode!(%{"ok" => false, "error" => inspect(reason)})
        end

      true ->
        case BotArmyTerrain.Ingestion.YamlImporter.import_file(resolved_path) do
          {:ok, result} ->
            Jason.encode!(%{
              "ok" => true,
              "track" => result.track,
              "track_id" => result.track_id,
              "chunks_imported" => result.chunks_imported,
              "chunks_updated" => result.chunks_updated,
              "requested_path" => path,
              "resolved_path" => resolved_path
            })

          {:error, reason} ->
            Jason.encode!(%{"ok" => false, "error" => inspect(reason)})
        end
    end
  end

  defp handle_request("terrain.track.import", msg) do
    # Alias for terrain.tracks.import (singular form)
    handle_request("terrain.tracks.import", msg)
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

      Jason.encode!(%{"ok" => true, "cards" => card_list})
    else
      Jason.encode!(%{"ok" => false, "error" => "track_id required", "cards" => []})
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
          Jason.encode!(%{"ok" => false, "error" => "card not found", "cards" => []})

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

            Jason.encode!(%{"ok" => true, "cards" => card_list})
          else
            Jason.encode!(%{"ok" => false, "error" => "card not embedded yet", "cards" => []})
          end
      end
    else
      Jason.encode!(%{"ok" => false, "error" => "card_id required", "cards" => []})
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
          "explanation" => l.explanation,
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

  defp handle_request("terrain.game.generate", msg) do
    track_id = msg["track_id"]

    cond do
      is_nil(track_id) ->
        Jason.encode!(%{"ok" => false, "error" => "track_id required"})

      is_nil(TrackStore.get_track(track_id)) ->
        Jason.encode!(%{"ok" => false, "error" => "track not found"})

      true ->
        BotArmyTerrain.GameGenerationWorker.queue_generation(track_id)
        Jason.encode!(%{"ok" => true, "status" => "queued"})
    end
  end

  defp handle_request("terrain.game.status", msg) do
    track_id = msg["track_id"]

    case BotArmyTerrain.GameStateStore.get_by_track(track_id) do
      nil ->
        Jason.encode!(%{"ok" => true, "status" => "not_generated"})

      game_state ->
        response = %{
          "ok" => true,
          "status" => game_state.status,
          "track_id" => game_state.track_id
        }

        response =
          if game_state.generated_at do
            Map.put(response, "generated_at", DateTime.to_iso8601(game_state.generated_at))
          else
            response
          end

        Jason.encode!(response)
    end
  end

  defp handle_request("terrain.game.get", msg) do
    track_id = msg["track_id"]

    case BotArmyTerrain.GameStateStore.get_by_track(track_id) do
      %{status: "active"} = game_state ->
        Jason.encode!(%{
          "ok" => true,
          "game_json" => game_state.game_json,
          "dojo_json" => game_state.dojo_json,
          "generated_at" => DateTime.to_iso8601(game_state.generated_at)
        })

      _ ->
        Jason.encode!(%{"ok" => false, "error" => "game not ready"})
    end
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

  # Maps container/TUI path prefixes to host runtime paths for bot-side file access.
  # Example: /app/lessons/elixir_bootcamp -> ${TERRAIN_LESSONS_ROOT}/elixir_bootcamp
  defp resolve_import_path(path) when is_binary(path) do
    lessons_root = System.get_env("TERRAIN_LESSONS_ROOT")

    cond do
      is_nil(lessons_root) or String.trim(lessons_root) == "" ->
        path

      String.starts_with?(path, "/app/lessons") ->
        suffix = String.replace_prefix(path, "/app/lessons", "") |> String.trim_leading("/")

        case suffix do
          "" -> lessons_root
          _ -> Path.join(lessons_root, suffix)
        end

      true ->
        path
    end
  end

  defp resolve_import_path(path), do: path
end
