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
  @registry_heartbeat_ms 20_000
  @version Mix.Project.config()[:version]

  @subjects [
    %{subject: "terrain.tracks.list", type: :request_reply, description: "List all tracks"},
    %{subject: "terrain.tracks.import", type: :request_reply, description: "Import track"},
    %{
      subject: "terrain.track.import",
      type: :request_reply,
      description: "Import track (singular)"
    },
    %{subject: "terrain.cards.due", type: :request_reply, description: "List due cards"},
    %{
      subject: "terrain.cards.list",
      type: :request_reply,
      description: "List every card in a deck (management)"
    },
    %{
      subject: "terrain.cards.create",
      type: :request_reply,
      description: "Add one card to a deck (management)"
    },
    %{
      subject: "terrain.cards.update",
      type: :request_reply,
      description: "Edit one card's front or back (management)"
    },
    %{
      subject: "terrain.cards.delete",
      type: :request_reply,
      description: "Remove one card from a deck (management; reversible)"
    },
    %{
      subject: "terrain.cards.restore",
      type: :request_reply,
      description: "Put a removed card back on its deck (management undo)"
    },
    %{
      subject: "terrain.tracks.create",
      type: :request_reply,
      description: "Create a deck (management)"
    },
    %{
      subject: "terrain.tracks.update",
      type: :request_reply,
      description: "Rename a deck or change its description (management)"
    },
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
        send_reply(state, reply_to, answer(topic, msg))

      {:error, reason} ->
        Logger.warning("Terrain decode failed: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  # One bad read is a refused read, never a dead handler.
  #
  # A raise inside a `handle_request/2` clause takes the whole RequestHandler down with it —
  # every registered read on this bot, not just the one that was asked. That has now happened
  # twice for the same reason (a clause calling a store with the wrong arity:
  # `terrain.game.get` with a nil track, and `terrain.session.stats` with one argument where
  # the store takes two), and both times the symptom on the far side was not an error but
  # **silence**: a request/reply with a dead handler simply times out. So the crash is caught
  # here, logged with its stacktrace, and answered as a refusal the caller can show.
  defp answer(topic, msg) do
    handle_request(topic, msg)
  rescue
    error ->
      Logger.error(
        "Terrain request #{topic} raised: #{Exception.message(error)}\n" <>
          Exception.format_stacktrace(__STACKTRACE__)
      )

      BotArmyLibraryRuntime.NATS.Reply.error(
        "this read failed inside the bot",
        :request_failed
      )
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

  @impl true
  def handle_info(:registry_heartbeat, state) do
    if state.subscriptions != [] do
      register_with_registry()
      Process.send_after(self(), :registry_heartbeat, @registry_heartbeat_ms)
    end

    {:noreply, state}
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
      "terrain.cards.list",
      "terrain.cards.create",
      "terrain.cards.update",
      "terrain.cards.delete",
      "terrain.cards.restore",
      "terrain.tracks.create",
      "terrain.tracks.update",
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

    # Same as the event handler: no `:nats, :connected` clause, so the
    # Connection must own the re-subscription. Registering the subjects against
    # this pid is what survives a replaced Gnat link.
    :ok = BotArmyLibraryRuntime.NATS.Connection.subscribe(subscriptions)
    Logger.info("Terrain subscribed to #{length(subscriptions)} subjects")
    results = subscriptions

    if Enum.all?(results, &(&1 != nil)) do
      register_with_registry()
      Process.send_after(self(), :registry_heartbeat, @registry_heartbeat_ms)
      {:noreply, %{state | subscriptions: results}}
    else
      schedule_reconnect(state)
    end
  end

  defp register_with_registry(attempts \\ 0)

  defp register_with_registry(attempts) when attempts > 3 do
    Logger.error("Terrain failed to register with registry")
    :error
  end

  defp register_with_registry(attempts) do
    deployment_status = Application.get_env(:bot_army_terrain, :deployment_status, "experimental")
    BotArmyLibraryRuntime.Registry.register("terrain", @subjects, @version, deployment_status)
    :ok
  rescue
    _e ->
      Process.sleep(100 * (attempts + 1))
      register_with_registry(attempts + 1)
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

  # `list_due_cards/3` is tenant-scoped and takes the tenant *first*. This clause used to
  # call `list_due_cards(track_id, limit: 20)`, which matched the default-argument arity
  # and put the track where the tenant belongs and `[limit: 20]` where the track belongs —
  # so every call to this subject raised inside the query builder rather than answering.
  # Nothing called it until the maid's panel did (2026-10-26), which is why the defect
  # survived: no test exercised the clause either. The store is read through the app env
  # now, like every other handler here, so the clause can be tested without a database.
  defp handle_request("terrain.cards.due", msg) do
    %{tenant_id: tenant_id} = BotArmyLibraryCore.Tenant.extract_context(msg)
    track_id = msg["track_id"]

    if track_id do
      store = Application.get_env(:bot_army_terrain, :card_store, BotArmyTerrain.CardStore)
      cards = store.list_due_cards(tenant_id, track_id, limit: 20)

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

  # ── the management door (2026-10-26) ────────────────────────────────────────────────────────
  #
  # Her question was "how do I manage collections and decks?", and the answer was "you cannot":
  # `CardStore` has had `create_card`/`update_card`/`delete_card` since the beginning and nothing
  # exposed them, a track's name was write-once (`get_or_create_track_by_name/2` looks a name up
  # and returns it), and the only way to add a card was to import a file that already lived on
  # this host. These six subjects are the door: a deck and the cards in it, read and written one
  # card at a time.
  #
  # They are *material*, not learning. A grade stays the review subjects above; these change what
  # there is to grade. Every one is tenant-scoped the same way the reads are, because the tenant
  # is what keeps one house's deck out of another's.

  defp handle_request("terrain.cards.list", msg) do
    %{tenant_id: tenant_id} = BotArmyLibraryCore.Tenant.extract_context(msg)

    case msg["track_id"] do
      track_id when is_binary(track_id) and track_id != "" ->
        cards = card_store().list_cards_for_track(tenant_id, track_id)

        BotArmyLibraryRuntime.NATS.Reply.ok(%{"cards" => Enum.map(cards, &card_row/1)})

      _other ->
        BotArmyLibraryRuntime.NATS.Reply.error("track_id required", :missing_track_id)
    end
  end

  defp handle_request("terrain.cards.create", msg) do
    %{tenant_id: tenant_id} = BotArmyLibraryCore.Tenant.extract_context(msg)
    track_id = msg["track_id"]

    cond do
      not is_binary(track_id) or track_id == "" ->
        BotArmyLibraryRuntime.NATS.Reply.error("track_id required", :missing_track_id)

      is_nil(track_store().get_track(track_id)) ->
        BotArmyLibraryRuntime.NATS.Reply.error("there is no deck with that id", :track_not_found)

      true ->
        attrs = %{
          track_id: track_id,
          front: blank_to_nil(msg["front"]),
          back: blank_to_nil(msg["back"]),
          card_type: msg["card_type"] || "basic"
        }

        case card_store().create_card(tenant_id, attrs) do
          {:ok, card} ->
            track_store().update_card_count_from_store(tenant_id, track_id)
            BotArmyLibraryRuntime.NATS.Reply.ok(%{"card" => card_row(card)})

          {:error, changeset} ->
            BotArmyLibraryRuntime.NATS.Reply.error(card_sentence(changeset), :card_refused)
        end
    end
  end

  defp handle_request("terrain.cards.update", msg) do
    %{tenant_id: tenant_id} = BotArmyLibraryCore.Tenant.extract_context(msg)

    with {:ok, card} <- find_card(tenant_id, msg["card_id"]) do
      attrs =
        %{}
        |> put_present("front", msg["front"])
        |> put_present("back", msg["back"])
        |> put_present("card_type", msg["card_type"])

      case card_store().update_card(tenant_id, card, attrs) do
        {:ok, card} ->
          BotArmyLibraryRuntime.NATS.Reply.ok(%{"card" => card_row(card)})

        {:error, changeset} ->
          BotArmyLibraryRuntime.NATS.Reply.error(card_sentence(changeset), :card_refused)
      end
    else
      {:error, :not_found} ->
        BotArmyLibraryRuntime.NATS.Reply.error("there is no card with that id", :card_not_found)
    end
  end

  defp handle_request("terrain.cards.delete", msg) do
    %{tenant_id: tenant_id} = BotArmyLibraryCore.Tenant.extract_context(msg)

    with {:ok, card} <- find_card(tenant_id, msg["card_id"]),
         {:ok, _deleted} <- card_store().delete_card(card.id) do
      track_store().update_card_count_from_store(tenant_id, card.track_id)
      BotArmyLibraryRuntime.NATS.Reply.ok(%{"deleted" => true, "id" => card.id})
    else
      {:error, :not_found} ->
        BotArmyLibraryRuntime.NATS.Reply.error("there is no card with that id", :card_not_found)

      {:error, reason} ->
        BotArmyLibraryRuntime.NATS.Reply.error(
          "the card could not be removed (#{inspect(reason)})",
          :card_not_removed
        )
    end
  end

  # The undo the page draws after a removal. A card that was never removed is not an error: the
  # answer is the card, because "it is on the deck" is what she asked for either way.
  defp handle_request("terrain.cards.restore", msg) do
    %{tenant_id: tenant_id} = BotArmyLibraryCore.Tenant.extract_context(msg)

    case card_store().restore_card(tenant_id, msg["card_id"]) do
      {:ok, card} ->
        track_store().update_card_count_from_store(tenant_id, card.track_id)
        BotArmyLibraryRuntime.NATS.Reply.ok(%{"card" => card_row(card), "restored" => true})

      {:error, :not_found} ->
        BotArmyLibraryRuntime.NATS.Reply.error("there is no card with that id", :card_not_found)

      {:error, changeset} ->
        BotArmyLibraryRuntime.NATS.Reply.error(card_sentence(changeset), :card_not_restored)
    end
  end

  defp handle_request("terrain.tracks.create", msg) do
    %{tenant_id: tenant_id} = BotArmyLibraryCore.Tenant.extract_context(msg)
    name = msg["name"] |> to_string() |> String.trim()

    cond do
      name == "" ->
        BotArmyLibraryRuntime.NATS.Reply.error("a deck needs a name", :missing_name)

      # There is no unique index on a deck's name, so the check is here. `get_or_create` would
      # hand back the existing deck instead of saying "this one is already here", and a press
      # that creates nothing and answers success is the shape of lie this door is meant to end.
      not is_nil(track_store().get_by_name(name)) ->
        BotArmyLibraryRuntime.NATS.Reply.error(
          "there is already a deck called #{name}",
          :track_exists
        )

      true ->
        attrs = %{name: name, tenant_id: tenant_id, description: blank_to_nil(msg["description"])}

        case track_store().create_track(attrs) do
          {:ok, track} ->
            BotArmyLibraryRuntime.NATS.Reply.ok(%{"track" => track_row(track)})

          {:error, changeset} ->
            BotArmyLibraryRuntime.NATS.Reply.error(track_sentence(changeset), :track_refused)
        end
    end
  end

  defp handle_request("terrain.tracks.update", msg) do
    %{tenant_id: tenant_id} = BotArmyLibraryCore.Tenant.extract_context(msg)
    track_id = msg["track_id"]

    with track when not is_nil(track) <- track_store().get_track(track_id),
         true <- track.tenant_id in [nil, tenant_id],
         attrs =
           %{}
           |> put_present("name", msg["name"])
           |> put_present("description", msg["description"]),
         false <- Map.has_key?(attrs, "name") and String.trim(attrs["name"]) == "",
         :ok <- deck_name_is_free(attrs["name"], track.id),
         {:ok, track} <- track_store().update_track(track, attrs) do
      BotArmyLibraryRuntime.NATS.Reply.ok(%{"track" => track_row(track)})
    else
      nil ->
        BotArmyLibraryRuntime.NATS.Reply.error("there is no deck with that id", :track_not_found)

      false ->
        BotArmyLibraryRuntime.NATS.Reply.error("a deck needs a name", :missing_name)

      {:error, :track_exists} ->
        # A rename that lands on a deck that already exists would leave two decks with one name,
        # and the chips are the only way to tell them apart.
        BotArmyLibraryRuntime.NATS.Reply.error(
          "there is already a deck called #{String.trim(msg["name"])}",
          :track_exists
        )

      {:error, %Ecto.Changeset{} = changeset} ->
        BotArmyLibraryRuntime.NATS.Reply.error(track_sentence(changeset), :track_refused)
    end
  end

  defp handle_request("terrain.session.start", msg) do
    SessionHandler.handle_start(msg)
  end

  defp handle_request("terrain.session.end", msg) do
    SessionHandler.handle_end(msg)
  end

  defp handle_request("terrain.session.stats", msg) do
    %{tenant_id: tenant_id} = BotArmyLibraryCore.Tenant.extract_context(msg)
    session_id = msg["session_id"]

    if session_id do
      store =
        Application.get_env(
          :bot_army_terrain,
          :review_session_store,
          BotArmyTerrain.ReviewSessionStore
        )

      # The store is tenant-scoped: `get_session_stats/2`, not `/1`. The clause called it with
      # one argument, so this subject answered nothing at all — it raised
      # `UndefinedFunctionError` and took the handler down on every ask. A session id alone is
      # not permission to read a session.
      case store.get_session_stats(tenant_id, session_id) do
        {:ok, stats} ->
          BotArmyLibraryRuntime.NATS.Reply.ok(stats)

        {:error, :not_found} ->
          BotArmyLibraryRuntime.NATS.Reply.error("no such session", :not_found)

        {:error, reason} ->
          BotArmyLibraryRuntime.NATS.Reply.error(stats_error(reason), :stats_error)
      end
    else
      BotArmyLibraryRuntime.NATS.Reply.error("session_id required", :missing_session_id)
    end
  end

  defp stats_error(:unauthorized), do: "that session belongs to another house"
  defp stats_error(other), do: "the session could not be read (#{inspect(other)})"

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

  # A review that carries a reply address is answered.
  #
  # It was not: the subject sat in `@subjects` above declared `:request_reply`, and yet only
  # the no-reply clause reached the handler, so a caller that *waited* for the ack fell
  # through to the catch-all below and was told `unknown_topic` — while the identical payload
  # published without a reply address recorded the review perfectly. The maid's panel waits,
  # because a page that has to re-read the deck to learn whether its own write landed is a
  # page guessing about a race it can see. Both shapes now reach the same handler.
  defp handle_request("terrain.review.submit", msg) do
    case record_review(msg) do
      :ok -> BotArmyLibraryRuntime.NATS.Reply.ok(%{"reviewed" => true})
      {:error, reason} -> BotArmyLibraryRuntime.NATS.Reply.error(review_error(reason), reason)
    end
  end

  defp handle_request(topic, _msg) do
    Logger.warning("Unknown request topic: #{topic}")
    BotArmyLibraryRuntime.NATS.Reply.error("unknown topic", :unknown_topic)
  end

  defp handle_event("terrain.review.submit", msg) do
    case record_review(msg) do
      :ok -> :ok
      {:error, reason} -> Logger.error("Review submit failed: #{inspect(reason)}")
    end
  end

  defp record_review(msg), do: BotArmyTerrain.Handlers.ReviewHandler.handle_submit(msg)

  # The refusal is read by a person on the card, so it is a sentence and not a term: an
  # `inspect/1` of `{:error, :card_not_found}` on her screen is the same defect the rpg
  # panel had (2026-10-26).
  defp review_error(:missing_card_id), do: "the press named no card"
  defp review_error(:card_not_found), do: "that card is no longer in the deck"
  defp review_error(:missing_quality), do: "the press carried no rating"
  defp review_error(:invalid_quality), do: "the rating was not one of the four"
  defp review_error(other), do: "the review was not recorded (#{inspect(other)})"

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
  defp card_store,
    do: Application.get_env(:bot_army_terrain, :card_store, BotArmyTerrain.CardStore)

  defp track_store,
    do: Application.get_env(:bot_army_terrain, :track_store, BotArmyTerrain.TrackStore)

  defp find_card(tenant_id, card_id) when is_binary(card_id) and card_id != "" do
    case card_store().get_card(tenant_id, card_id) do
      nil -> {:error, :not_found}
      card -> {:ok, card}
    end
  end

  defp find_card(_tenant_id, _card_id), do: {:error, :not_found}

  # A field that was not sent is not a field to clear: `""` from a form means "I emptied it",
  # a missing key means "I did not touch it". Cards refuse an empty front or back, so a blank
  # is turned into nil and refused by the changeset rather than blanking a card that has one.
  defp put_present(attrs, _key, nil), do: attrs
  defp put_present(attrs, key, value), do: Map.put(attrs, key, blank_to_nil(value))

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp deck_name_is_free(nil, _track_id), do: :ok

  defp deck_name_is_free(name, track_id) do
    case track_store().get_by_name(String.trim(name)) do
      nil -> :ok
      %{id: ^track_id} -> :ok
      _other -> {:error, :track_exists}
    end
  end

  defp card_row(card) do
    %{
      "id" => card.id,
      "track_id" => card.track_id,
      "front" => card.front,
      "back" => card.back,
      "card_type" => card.card_type,
      "state" => card.state,
      "next_review_at" => card.next_review_at && DateTime.to_iso8601(card.next_review_at)
    }
  end

  # `Map.get/3` rather than `track.description`: the row is also built from a mock's map in
  # tests, and a struct-only field access raises a KeyError there — which the `answer/2` rescue
  # would turn into "this read failed inside the bot" instead of a deck.
  defp track_row(track) do
    %{
      "id" => Map.get(track, :id),
      "name" => Map.get(track, :name),
      "description" => Map.get(track, :description),
      "card_count" => Map.get(track, :card_count) || 0,
      "chunk_count" => Map.get(track, :chunk_count) || 0,
      "status" => Map.get(track, :status)
    }
  end

  # A changeset is a struct full of field maps, and a refusal read by a person is a sentence.
  defp card_sentence(%Ecto.Changeset{} = changeset),
    do: sentence_from(changeset, "the card was refused")

  defp card_sentence(_other), do: "the card was refused"

  defp track_sentence(%Ecto.Changeset{} = changeset),
    do: sentence_from(changeset, "the deck was refused")

  defp track_sentence(_other), do: "the deck was refused"

  defp sentence_from(changeset, fallback) do
    messages =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
      |> Enum.flat_map(fn {_field, messages} -> messages end)

    case messages do
      [] -> fallback
      [message | _rest] -> message
    end
  end

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
