defmodule BotArmyTerrain.Handlers.LessonHandler do
  @moduledoc """
  Handler for generating lessons via LLM.

  Takes chunk content and calls LLM to generate explanations.
  Returns structured lesson with title and explanation.
  """

  require Logger

  @doc """
  Generate a lesson for a chunk using LLM.

  Returns {:ok, lesson_map} or {:error, reason}.
  """
  def generate_lesson(chunk_id, chunk_title, chunk_content) do
    prompt = build_lesson_prompt(chunk_title, chunk_content)

    case call_llm(chunk_id, chunk_title, prompt) do
      {:ok, response} ->
        parse_lesson_response(chunk_id, response)

      {:error, reason} ->
        Logger.error("LLM call failed for lesson #{chunk_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_lesson_prompt(chunk_title, chunk_content) do
    """
    You are an expert educator creating a detailed learning lesson.

    Concept: #{chunk_title}

    Context: #{chunk_content}

    Generate a comprehensive lesson explanation that:
    1. Explains the core concept clearly
    2. Provides practical examples
    3. Lists key learning points
    4. Suggests how to practice/apply
    5. Includes edge cases or common misconceptions

    Format your response as:
    TITLE: [Clear lesson title]
    EXPLANATION: [Detailed explanation with formatting]
    EXTERNAL_LINK: [If known, a URL for further reading; otherwise ""]
    """
  end

  defp call_llm(chunk_id, chunk_title, prompt) do
    payload = %{
      "prompt" => prompt,
      "context" => chunk_title
    }

    source_metadata = %{
      "source_domain" => "lesson_generation",
      "chunk_id" => chunk_id
    }

    request = %{
      "event" => "llm.prompt.submit",
      "event_id" => UUID.uuid4() |> to_string(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_terrain",
      "source_node" => get_node_name(),
      "triggered_by" => "lesson_handler",
      "schema_version" => "1.0",
      "source_metadata" => source_metadata,
      "payload" => payload
    }

    # For now, return a demo lesson
    # Phase 2: Implement actual LLM call via NATS
    case send_llm_request(request) do
      :ok ->
        # Return demo lesson for now
        {:ok, build_demo_lesson(chunk_id, chunk_title)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_llm_request(request) do
    case get_connection() do
      {:ok, conn} ->
        subject = "events.llm.prompt.submit"

        case Gnat.pub(conn, subject, Jason.encode!(request)) do
          :ok ->
            Logger.debug("Sent LLM request for lesson generation")
            :ok

          {:error, reason} ->
            Logger.error("Failed to send LLM request: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, _} ->
        Logger.error("NATS unavailable for LLM request")
        {:error, :nats_unavailable}
    end
  end

  defp parse_lesson_response(chunk_id, response) do
    attrs = %{
      "chunk_id" => chunk_id,
      "title" => response["title"],
      "explanation" => response["explanation"],
      "external_link" => Map.get(response, "external_link", ""),
      "generated_at" => DateTime.utc_now()
    }

    case BotArmyTerrain.LessonStore.store_lesson(attrs) do
      {:ok, lesson} ->
        # Queue for background vectorization
        BotArmyTerrain.LessonEmbedWorker.queue_lesson(lesson.id)

        {:ok,
         %{
           "chunk_id" => chunk_id,
           "title" => lesson.title,
           "explanation" => lesson.explanation,
           "external_link" => lesson.external_link,
           "generated_at" => DateTime.to_iso8601(lesson.generated_at)
         }}

      {:error, reason} ->
        Logger.error("Failed to store lesson #{chunk_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_demo_lesson(chunk_id, chunk_title) do
    demo_explanation =
      "This lesson explains #{chunk_title}.\n\n" <>
        "Key points:\n" <>
        "1. Foundational concept\n" <>
        "2. Practical application\n" <>
        "3. Common pitfalls\n\n" <>
        "(This is a demo lesson. Full LLM-generated lessons coming in Phase 2.)"

    attrs = %{
      "chunk_id" => chunk_id,
      "title" => "Understanding: #{chunk_title}",
      "explanation" => demo_explanation,
      "external_link" => "",
      "generated_at" => DateTime.utc_now()
    }

    case BotArmyTerrain.LessonStore.store_lesson(attrs) do
      {:ok, lesson} ->
        %{
          "chunk_id" => chunk_id,
          "title" => lesson.title,
          "explanation" => lesson.explanation,
          "external_link" => lesson.external_link,
          "generated_at" => DateTime.to_iso8601(lesson.generated_at)
        }

      {:error, _reason} ->
        # Fallback to in-memory demo if storage fails
        %{
          "chunk_id" => chunk_id,
          "title" => "Understanding: #{chunk_title}",
          "explanation" => demo_explanation,
          "external_link" => "",
          "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }
    end
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

  defp get_node_name do
    case :inet.gethostname() do
      {:ok, hostname} -> to_string(hostname)
      {:error, _} -> "unknown"
    end
  end
end
