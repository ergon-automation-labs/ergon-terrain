defmodule BotArmyTerrain.Handlers.GameCompletionHandler do
  @moduledoc """
  Handles LLM completion events for game generation (both phases: game and dojo).
  Routes phase 1 completion to phase 2 generation.
  """

  require Logger

  alias BotArmyTerrain.GameStateStore
  alias BotArmyTerrain.LessonStore
  alias BotArmyTerrain.Handlers.GameGenerationHandler
  alias BotArmyRuntime.NATS.Connection

  def handle_completion(message) do
    %{tenant_id: tenant_id, user_id: user_id} = BotArmyCore.Tenant.extract_context(message)
    payload = message["payload"] || %{}
    source_metadata = message["source_metadata"] || %{}

    track_id = source_metadata["track_id"]
    phase = source_metadata["phase"]
    completion_text = payload["completion"]

    Logger.info("Terrain: game completion event for track #{track_id}, phase #{phase}")

    # Strip markdown code fences if present
    json_text = strip_code_fences(completion_text)

    case {phase, Jason.decode(json_text)} do
      {"game", {:ok, game_json}} ->
        BotArmyRuntime.Outcomes.emit("terrain", "generation", "game_phase_parsed", 1,
          metadata: %{track_id: track_id, tenant_id: tenant_id}
        )

        handle_game_phase_complete(tenant_id, user_id, track_id, game_json)

      {"dojo", {:ok, dojo_json}} ->
        BotArmyRuntime.Outcomes.emit("terrain", "generation", "dojo_phase_parsed", 1,
          metadata: %{track_id: track_id, tenant_id: tenant_id}
        )

        handle_dojo_phase_complete(tenant_id, user_id, track_id, dojo_json)

      {phase, {:error, decode_error}} ->
        Logger.error(
          "Terrain: failed to parse LLM JSON for track #{track_id}, phase #{phase}: #{inspect(decode_error)}"
        )

        GameStateStore.mark_status(tenant_id, track_id, "stale")

        emit_event("terrain.game.generation.failed", %{
          "track_id" => track_id,
          "phase" => phase,
          "tenant_id" => tenant_id,
          "user_id" => user_id
        })

        BotArmyRuntime.Outcomes.emit("terrain", "generation", "game_generation_parse_failed", 0,
          metadata: %{
            track_id: track_id,
            phase: phase,
            tenant_id: tenant_id,
            reason: inspect(decode_error)
          }
        )

        {:error, decode_error}
    end
  end

  defp handle_game_phase_complete(tenant_id, user_id, track_id, _game_json_data) do
    Logger.info("Terrain: game phase complete for track #{track_id}, starting dojo phase")

    # Store the game JSON
    GameStateStore.upsert(tenant_id, %{
      track_id: track_id,
      game_json: Jason.encode!(_game_json_data),
      status: "generating_dojo"
    })

    # Trigger dojo generation
    lessons = LessonStore.list_lessons_by_track(tenant_id, track_id)
    GameGenerationHandler.generate_dojo(tenant_id, user_id, track_id, lessons)

    emit_event("terrain.game.generation.progress", %{
      "track_id" => track_id,
      "phase" => "dojo",
      "tenant_id" => tenant_id,
      "user_id" => user_id
    })
  end

  defp handle_dojo_phase_complete(tenant_id, user_id, track_id, _dojo_json_data) do
    Logger.info("Terrain: dojo phase complete for track #{track_id}")

    # Store the dojo JSON and mark as active
    case GameStateStore.upsert(tenant_id, %{
           track_id: track_id,
           dojo_json: Jason.encode!(_dojo_json_data),
           status: "active",
           generated_at: DateTime.utc_now(:microsecond)
         }) do
      {:ok, _} ->
        emit_event("terrain.game.generation.completed", %{
          "track_id" => track_id,
          "tenant_id" => tenant_id,
          "user_id" => user_id
        })

        Logger.info("Terrain: game generation completed for track #{track_id}")

        BotArmyRuntime.Outcomes.emit("terrain", "generation", "game_generation_completed", 1,
          metadata: %{track_id: track_id, tenant_id: tenant_id}
        )

      {:error, reason} ->
        Logger.error(
          "Terrain: failed to store dojo state for track #{track_id}: #{inspect(reason)}"
        )

        emit_event("terrain.game.generation.failed", %{
          "track_id" => track_id,
          "phase" => "dojo",
          "tenant_id" => tenant_id,
          "user_id" => user_id
        })

        BotArmyRuntime.Outcomes.emit("terrain", "generation", "game_generation_store_failed", 0,
          metadata: %{track_id: track_id, tenant_id: tenant_id, reason: inspect(reason)}
        )
    end
  end

  defp strip_code_fences(text) do
    text
    |> String.replace(~r/```json\n?/, "")
    |> String.replace(~r/```\n?/, "")
    |> String.trim()
  end

  defp emit_event(event_name, payload) do
    tenant_id = payload["tenant_id"]
    user_id = payload["user_id"]

    case Connection.get_connection() do
      {:ok, conn} ->
        envelope = %{
          "event" => event_name,
          "event_id" => Elixir.UUID.uuid4(),
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "source" => "bot_army_terrain",
          "source_node" => :inet.gethostname() |> elem(1) |> to_string(),
          "schema_version" => "1.0",
          "tenant_id" => tenant_id,
          "user_id" => user_id,
          "payload" => payload
        }

        Gnat.pub(conn, "events.#{event_name}", Jason.encode!(envelope))

      {:error, _} ->
        Logger.warning("Terrain: NATS unavailable, skipping event #{event_name}")
    end
  end
end
