defmodule BotArmyTerrain.Handlers.LessonCompletionHandler do
  @moduledoc """
  Handler for async LLM lesson generation completion events.

  Receives events.llm.completion.terrain.lesson_generation, parses the LLM response,
  stores the lesson to database, queues embedding, and emits completion/failure events.
  """

  require Logger

  @doc """
  Handle LLM completion event for lesson generation.

  Expected message shape:
    %{
      "payload" => %{
        "completion" => "<raw LLM text with labeled fields>",
        ...
      },
      "source_metadata" => %{
        "chunk_id" => "...",
        ...
      },
      ...
    }
  """
  def handle_completion(message) do
    %{tenant_id: tenant_id, user_id: user_id} = BotArmyLibraryCore.Tenant.extract_context(message)
    payload = message["payload"] || %{}
    source_metadata = message["source_metadata"] || %{}

    chunk_id = source_metadata["chunk_id"]
    completion_text = payload["completion"]

    if is_nil(chunk_id) or is_nil(completion_text) do
      Logger.warning(
        "LessonCompletionHandler: missing chunk_id or completion in message"
      )

      :ignore
    else
      parsed = BotArmyTerrain.Handlers.LessonHandler.parse_llm_text(completion_text)

      attrs =
        Map.merge(parsed, %{
          "chunk_id" => chunk_id,
          "generated_at" => DateTime.utc_now()
        })

      case BotArmyTerrain.LessonStore.store_lesson(tenant_id, attrs) do
        {:ok, lesson} ->
          BotArmyTerrain.LessonEmbedWorker.queue_lesson(tenant_id, lesson.id)
          emit_completed_event(tenant_id, user_id, chunk_id, lesson)
          :ok

        {:error, reason} ->
          Logger.error(
            "LessonCompletionHandler: failed to store lesson for #{chunk_id}: #{inspect(reason)}"
          )

          emit_failed_event(tenant_id, user_id, chunk_id, reason)
          :error
      end
    end
  end

  defp emit_completed_event(tenant_id, user_id, chunk_id, lesson) do
    emit_event("terrain.lesson.generation.completed", %{
      "chunk_id" => chunk_id,
      "lesson_id" => lesson.id,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "tenant_id" => tenant_id,
      "user_id" => user_id
    })
  end

  defp emit_failed_event(tenant_id, user_id, chunk_id, reason) do
    emit_event("terrain.lesson.generation.failed", %{
      "chunk_id" => chunk_id,
      "reason" => inspect(reason),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "tenant_id" => tenant_id,
      "user_id" => user_id
    })
  end

  defp emit_event(event_name, payload) do
    tenant_id = payload["tenant_id"]
    user_id = payload["user_id"]

    envelope = %{
      "event" => event_name,
      "event_id" => UUID.uuid4() |> to_string(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_terrain",
      "triggered_by" => "lesson_completion_handler",
      "schema_version" => "1.0",
      "tenant_id" => tenant_id,
      "user_id" => user_id,
      "payload" => payload
    }

    case get_connection() do
      {:ok, conn} ->
        case Gnat.pub(conn, "events.#{event_name}", Jason.encode!(envelope)) do
          :ok ->
            Logger.debug("Emitted event: #{event_name}")

          {:error, reason} ->
            Logger.error("Failed to emit event #{event_name}: #{inspect(reason)}")
        end

      {:error, _} ->
        Logger.warning("NATS unavailable, event not emitted: #{event_name}")
    end
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
end
