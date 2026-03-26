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
    You are an expert educator creating a detailed learning lesson and quiz show question.

    Concept: #{chunk_title}

    Context: #{chunk_content}

    Generate a comprehensive lesson explanation that:
    1. Explains the core concept clearly
    2. Provides practical examples
    3. Lists key learning points
    4. Suggests how to practice/apply
    5. Includes edge cases or common misconceptions

    Then create a quiz question and multiple choice answers with a snarky game show host.

    Format your response as:
    TITLE: [Clear lesson title]
    EXPLANATION: [Detailed explanation with formatting]
    EXTERNAL_LINK: [If known, a URL for further reading; otherwise ""]
    QUIZ_QUESTION: [One clear question that tests understanding of this concept]
    OPTION_1: [One of 4 answer choices — vary which position is correct]
    OPTION_2: [One of 4 answer choices]
    OPTION_3: [One of 4 answer choices]
    OPTION_4: [One of 4 answer choices]
    CORRECT_OPTION: [1, 2, 3, or 4]
    HOST_INTRO: [1-2 sentences of snarky game show host energy setting up the question]
    HOST_CORRECT: [1-2 sentences: celebratory but slightly smug, reference the concept]
    HOST_WRONG: [1-2 sentences: cutting/snarky judgment, lightly roast the wrong answer, still clarify the concept]
    NPC_1_NAME: [Amusing wrong-contestant name, e.g. "Confused Carl", "Overconfident Owen"]
    NPC_1_ANSWER: [1/2/3/4 — must be a wrong answer option]
    NPC_2_NAME: [Another amusing wrong-contestant name]
    NPC_2_ANSWER: [1/2/3/4 — must be wrong, and different from NPC_1_ANSWER]
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
      "quiz_question" => Map.get(response, "quiz_question"),
      "quiz_options" => Map.get(response, "quiz_options", []),
      "quiz_correct_index" => Map.get(response, "quiz_correct_index"),
      "host_intro" => Map.get(response, "host_intro"),
      "host_correct" => Map.get(response, "host_correct"),
      "host_wrong" => Map.get(response, "host_wrong"),
      "npc_players" => Map.get(response, "npc_players", []),
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
           "quiz_question" => lesson.quiz_question,
           "quiz_options" => lesson.quiz_options,
           "quiz_correct_index" => lesson.quiz_correct_index,
           "host_intro" => lesson.host_intro,
           "host_correct" => lesson.host_correct,
           "host_wrong" => lesson.host_wrong,
           "npc_players" => lesson.npc_players,
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
      "quiz_question" => "Which statement about #{chunk_title} is most accurate?",
      "quiz_options" => [
        "It is a core concept with practical applications",
        "It is rarely used in production code",
        "It only applies to advanced use cases",
        "It is specific to functional programming only"
      ],
      "quiz_correct_index" => 0,
      "host_intro" => "Let's test your understanding of #{chunk_title}! The stakes are high and your dignity is on the line.",
      "host_correct" => "Well done! You clearly understand #{chunk_title} better than your fellow contestants.",
      "host_wrong" => "Oh fascinating choice. Tragically, also wrong. #{chunk_title} is a core concept — perhaps the dojo will help.",
      "npc_players" => [
        %{"name" => "Confused Carl", "answer_index" => 1},
        %{"name" => "Overconfident Owen", "answer_index" => 2}
      ],
      "generated_at" => DateTime.utc_now()
    }

    case BotArmyTerrain.LessonStore.store_lesson(attrs) do
      {:ok, lesson} ->
        %{
          "chunk_id" => chunk_id,
          "title" => lesson.title,
          "explanation" => lesson.explanation,
          "external_link" => lesson.external_link,
          "quiz_question" => lesson.quiz_question,
          "quiz_options" => lesson.quiz_options,
          "quiz_correct_index" => lesson.quiz_correct_index,
          "host_intro" => lesson.host_intro,
          "host_correct" => lesson.host_correct,
          "host_wrong" => lesson.host_wrong,
          "npc_players" => lesson.npc_players,
          "generated_at" => DateTime.to_iso8601(lesson.generated_at)
        }

      {:error, _reason} ->
        # Fallback to in-memory demo if storage fails
        %{
          "chunk_id" => chunk_id,
          "title" => "Understanding: #{chunk_title}",
          "explanation" => demo_explanation,
          "external_link" => "",
          "quiz_question" => "Which statement about #{chunk_title} is most accurate?",
          "quiz_options" => [
            "It is a core concept with practical applications",
            "It is rarely used in production code",
            "It only applies to advanced use cases",
            "It is specific to functional programming only"
          ],
          "quiz_correct_index" => 0,
          "host_intro" => "Let's test your understanding of #{chunk_title}!",
          "host_correct" => "Well done! You understand #{chunk_title}.",
          "host_wrong" => "Not quite right. Study the dojo for more help.",
          "npc_players" => [
            %{"name" => "Confused Carl", "answer_index" => 1},
            %{"name" => "Overconfident Owen", "answer_index" => 2}
          ],
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
