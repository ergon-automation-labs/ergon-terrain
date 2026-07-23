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

  @subjects [
    %{subject: "terrain.tracks.list", type: :request_reply, description: "List all tracks"},
    %{subject: "terrain.tracks.import", type: :request_reply, description: "Import track"},
    %{
      subject: "terrain.track.import",
      type: :request_reply,
      description: "Import track (singular)"
    },
    %{subject: "terrain.cards.due", type: :request_reply, description: "List due cards"},
    %{subject: "terrain.review.submit", type: :request_reply, description: "Submit review"},
    %{
      subject: "terrain.session.start",
      type: :request_reply,
      description: "Start review session"
    },
    %{subject: "terrain.session.end", type: :request_reply, description: "End review session"},
    %{subject: "terrain.session.stats", type: :request_reply, description: "Get session stats"},
    %{subject: "terrain.cards.similar", type: :request_reply, description: "Find similar cards"},
    %{
      subject: "terrain.lesson.generation.request",
      type: :request_reply,
      description: "Request lesson generation"
    },
    %{subject: "terrain.lesson.get", type: :request_reply, description: "Get lesson"},
    %{subject: "terrain.lesson.list", type: :request_reply, description: "List lessons"},
    %{subject: "terrain.game.generate", type: :request_reply, description: "Generate game"},
    %{subject: "terrain.game.status", type: :request_reply, description: "Get game status"},
    %{subject: "terrain.game.get", type: :request_reply, description: "Get game data"},
    %{
      subject: "terrain.system.srs_signal",
      type: :request_reply,
      description: "System-wide SM-2 signal for retry confidence"
    }
  ]

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
      {:ok, conn} ->
        BotArmyLibraryRuntime.Health.Responder.register_subjects(@subjects)
        subscribe(conn, state)

      {:error, _} ->
        schedule_reconnect(state)
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
      GenServer.call(BotArmyLibraryRuntime.NATS.Connection, :get_connection, 5000)
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
      "terrain.game.get",
      "terrain.system.srs_signal"
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

  defp handle_request("terrain.tracks.list", msg) do
    %{tenant_id: tenant_id} = BotArmyLibraryCore.Tenant.extract_context(msg)
    tracks = TrackStore.list_tracks(status: "active")

    track_list =
      Enum.map(tracks, fn track ->
        cards_due = CardStore.count_due_cards(tenant_id, track.id)

        %{
          "id" => track.id,
          "name" => track.name,
          "card_count" => track.card_count || 0,
          "chunk_count" => track.chunk_count || 0,
          "cards_due" => cards_due || 0,
          "status" => track.status,
          "last_reviewed_at" => track.updated_at && DateTime.to_iso8601(track.updated_at)
        }
      end)

    BotArmyLibraryRuntime.NATS.Reply.ok(%{"tracks" => track_list})
  end

  defp handle_request("terrain.tracks.import", msg) do
    path = msg["path"]
    resolved_path = resolve_import_path(path)

    cond do
      is_nil(path) ->
        BotArmyLibraryRuntime.NATS.Reply.error("path required", :missing_path)

      not File.exists?(resolved_path) ->
        BotArmyLibraryRuntime.NATS.Reply.error(
          "file not found: #{resolved_path}",
          :file_not_found
        )

      File.dir?(resolved_path) ->
        # Queue directory import asynchronously to avoid blocking RequestHandler
        _task =
          Task.start(fn ->
            case BotArmyTerrain.Ingestion.LessonDirectoryImporter.import_directory(resolved_path) do
              {:ok, result} ->
                Logger.info(
                  "Track import queued: #{path} → #{result.tracks_imported} tracks, #{result.lessons_imported} lessons"
                )

              {:error, reason} ->
                Logger.error("Track import failed: #{path} → #{inspect(reason)}")
            end
          end)

        BotArmyLibraryRuntime.NATS.Reply.ok(%{
          "status" => "queued",
          "requested_path" => path,
          "resolved_path" => resolved_path,
          "message" => "Track import queued for background processing"
        })

      true ->
        # Queue file import asynchronously to avoid blocking RequestHandler
        _task =
          Task.start(fn ->
            case BotArmyTerrain.Ingestion.YamlImporter.import_file(resolved_path) do
              {:ok, result} ->
                Logger.info(
                  "Track import completed: #{path} → #{result.track}, #{result.chunks_imported} chunks"
                )

              {:error, reason} ->
                Logger.error("Track import failed: #{path} → #{inspect(reason)}")
            end
          end)

        BotArmyLibraryRuntime.NATS.Reply.ok(%{
          "status" => "queued",
          "requested_path" => path,
          "resolved_path" => resolved_path,
          "message" => "Track import queued for background processing"
        })
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

      BotArmyLibraryRuntime.NATS.Reply.ok(%{"cards" => card_list})
    else
      BotArmyLibraryRuntime.NATS.Reply.error("track_id required", :missing_track_id)
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
      store =
        Application.get_env(
          :bot_army_terrain,
          :review_session_store,
          BotArmyTerrain.ReviewSessionStore
        )

      case store.get_session_stats(session_id) do
        {:ok, stats} -> BotArmyLibraryRuntime.NATS.Reply.ok(stats)
        {:error, reason} -> BotArmyLibraryRuntime.NATS.Reply.error(inspect(reason), :stats_error)
      end
    else
      BotArmyLibraryRuntime.NATS.Reply.error("session_id required", :missing_session_id)
    end
  end

  defp handle_request("terrain.cards.similar", msg) do
    %{tenant_id: tenant_id} = BotArmyLibraryCore.Tenant.extract_context(msg)
    card_id = msg["card_id"]
    limit = msg["limit"] || 5

    if card_id do
      case CardStore.get_card(tenant_id, card_id) do
        nil ->
          BotArmyLibraryRuntime.NATS.Reply.error("card not found", :card_not_found)

        card ->
          if card.embedding_vector do
            similar_cards =
              CardStore.find_similar_cards(card.track_id, card.embedding_vector, limit)

            card_list =
              Enum.map(similar_cards, fn result ->
                %{
                  "id" => result.id,
                  "front" => result.front,
                  "back" => result.back,
                  "similarity" => result.similarity
                }
              end)

            BotArmyLibraryRuntime.NATS.Reply.ok(%{"cards" => card_list})
          else
            BotArmyLibraryRuntime.NATS.Reply.error("card not embedded yet", :card_not_embedded)
          end
      end
    else
      BotArmyLibraryRuntime.NATS.Reply.error("card_id required", :missing_card_id)
    end
  end

  defp handle_request("terrain.lesson.generation.request", msg) do
    chunk_id = msg["chunk_id"]
    chunk_title = msg["chunk_title"] || ""
    chunk_content = msg["chunk_content"] || ""

    if chunk_id && chunk_title && chunk_content do
      # Queue for background generation
      BotArmyTerrain.LessonGenerationWorker.queue_lesson(chunk_id, chunk_title, chunk_content)

      BotArmyLibraryRuntime.NATS.Reply.ok(%{
        "queued" => true,
        "chunk_id" => chunk_id,
        "message" => "Lesson generation queued"
      })
    else
      BotArmyLibraryRuntime.NATS.Reply.error(
        "chunk_id, chunk_title, and chunk_content required",
        :missing_fields
      )
    end
  end

  defp handle_request("terrain.lesson.get", msg) do
    chunk_id = msg["chunk_id"]
    tenant_id = msg["tenant_id"] || BotArmyLibraryCore.Tenant.default_tenant_id()

    case BotArmyTerrain.LessonStore.get_lesson_by_chunk(tenant_id, chunk_id) do
      nil ->
        BotArmyLibraryRuntime.NATS.Reply.error("lesson not found", :lesson_not_found)

      lesson ->
        BotArmyLibraryRuntime.NATS.Reply.ok(%{
          "chunk_id" => lesson.chunk_id,
          "title" => lesson.title,
          "explanation" => lesson.explanation,
          "external_link" => lesson.external_link || "",
          "difficulty" => lesson.difficulty,
          "quiz_question" => lesson.quiz_question,
          "quiz_options" => lesson.quiz_options || [],
          "quiz_correct_index" => lesson.quiz_correct_index,
          "quiz_questions" => lesson.quiz_questions || [],
          "host_intro" => lesson.host_intro,
          "host_correct" => lesson.host_correct,
          "host_wrong" => lesson.host_wrong,
          "npc_players" => lesson.npc_players || [],
          "generated_at" => DateTime.to_iso8601(lesson.generated_at)
        })
    end
  end

  defp handle_request("terrain.lesson.list", msg) do
    tenant_id = msg["tenant_id"] || BotArmyLibraryCore.Tenant.default_tenant_id()
    lessons = BotArmyTerrain.LessonStore.list_lessons(tenant_id)

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

    BotArmyLibraryRuntime.NATS.Reply.ok(%{
      "lessons" => lesson_list
    })
  end

  defp handle_request("terrain.game.generate", msg) do
    track_id = msg["track_id"]

    cond do
      is_nil(track_id) ->
        BotArmyLibraryRuntime.NATS.Reply.error("track_id required", :missing_track_id)

      is_nil(TrackStore.get_track(track_id)) ->
        BotArmyLibraryRuntime.NATS.Reply.error("track not found", :track_not_found)

      true ->
        BotArmyTerrain.GameGenerationWorker.queue_generation(track_id)
        BotArmyLibraryRuntime.NATS.Reply.ok(%{"status" => "queued"})
    end
  end

  defp handle_request("terrain.game.status", msg) do
    %{tenant_id: tenant_id} = BotArmyLibraryCore.Tenant.extract_context(msg)
    track_id = msg["track_id"]

    case BotArmyTerrain.GameStateStore.get_by_track(tenant_id, track_id) do
      nil ->
        BotArmyLibraryRuntime.NATS.Reply.ok(%{"status" => "not_generated"})

      game_state ->
        response = %{
          "status" => game_state.status,
          "track_id" => game_state.track_id
        }

        response =
          if game_state.generated_at do
            Map.put(response, "generated_at", DateTime.to_iso8601(game_state.generated_at))
          else
            response
          end

        BotArmyLibraryRuntime.NATS.Reply.ok(response)
    end
  end

  defp handle_request("terrain.game.get", msg) do
    %{tenant_id: tenant_id} = BotArmyLibraryCore.Tenant.extract_context(msg)
    track_id = msg["track_id"]

    case BotArmyTerrain.GameStateStore.get_by_track(tenant_id, track_id) do
      %{status: "active"} = game_state ->
        BotArmyLibraryRuntime.NATS.Reply.ok(%{
          "game_json" => game_state.game_json,
          "dojo_json" => game_state.dojo_json,
          "generated_at" => DateTime.to_iso8601(game_state.generated_at)
        })

      _ ->
        BotArmyLibraryRuntime.NATS.Reply.error("game not ready", :game_not_ready)
    end
  end

  defp handle_request("terrain.system.srs_signal", msg) do
    BotArmyTerrain.Handlers.SystemSignalHandler.handle_request(msg)
  end

  defp handle_request(topic, _msg) do
    Logger.warning("Unknown request topic: #{topic}")
    BotArmyLibraryRuntime.NATS.Reply.error("unknown topic", :unknown_topic)
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
  # /app/lessons_bot_army/* -> /etc/bot_army/lessons/* (bot-accessible, always works)
  # /app/lessons/* -> ${TERRAIN_LESSONS_ROOT}/* (user paths, dev default)
  defp resolve_import_path(path) when is_binary(path) do
    cond do
      String.starts_with?(path, "/app/lessons_bot_army") ->
        # Bot-accessible path: always maps to /etc/bot_army/lessons
        suffix =
          String.replace_prefix(path, "/app/lessons_bot_army", "") |> String.trim_leading("/")

        case suffix do
          "" -> "/etc/bot_army/lessons"
          _ -> Path.join("/etc/bot_army/lessons", suffix)
        end

      String.starts_with?(path, "/app/lessons") ->
        # User path: maps to configured root (defaults to user home for dev)
        lessons_root = configured_lessons_root()

        if is_nil(lessons_root) or String.trim(lessons_root) == "" do
          path
        else
          suffix = String.replace_prefix(path, "/app/lessons", "") |> String.trim_leading("/")

          case suffix do
            "" -> lessons_root
            _ -> Path.join(lessons_root, suffix)
          end
        end

      true ->
        path
    end
  end

  defp resolve_import_path(path), do: path

  # Resolve /app/lessons paths to the bot-readable location.
  # Prefer explicit TERRAIN_LESSONS_ROOT env var, but default to /etc/bot_army/lessons
  # (where Salt deploys files and bot_army user has read access).
  defp configured_lessons_root do
    env_root = System.get_env("TERRAIN_LESSONS_ROOT")

    if is_binary(env_root) and String.trim(env_root) != "" do
      env_root
    else
      "/etc/bot_army/lessons"
    end
  end
end
