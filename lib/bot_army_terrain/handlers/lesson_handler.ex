defmodule BotArmyTerrain.Handlers.LessonHandler do
  @moduledoc """
  Handler for generating lessons via LLM.

  Takes chunk content and calls LLM to generate explanations.
  Returns structured lesson with title and explanation.
  """

  require Logger
  require Regex

  @doc """
  Generate a lesson for a chunk using LLM.

  Submits to LLM asynchronously (fire-and-forget). Returns {:ok, :submitted} if LLM request succeeds.
  If NATS unavailable, falls back to demo lesson synchronously.
  Actual lesson data arrives asynchronously via LessonCompletionHandler.
  """
  def generate_lesson(chunk_id, chunk_title, chunk_content) do
    case submit_llm_request(chunk_id, chunk_title, chunk_content) do
      :ok ->
        # LLM request submitted — lesson data will arrive asynchronously
        {:ok, :submitted}

      {:error, :nats_unavailable} ->
        # NATS not available — fall back to demo lesson generated synchronously
        demo = build_demo_lesson(chunk_id, chunk_title)
        {:ok, demo}

      {:error, reason} ->
        Logger.error("LLM request failed for lesson #{chunk_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Submit LLM request for lesson generation (fire-and-forget).

  Publishes to "llm.prompt.submit" with proper envelope and payload fields.
  Does NOT wait for response — completion handled async by LessonCompletionHandler.
  """
  def submit_llm_request(chunk_id, chunk_title, chunk_content) do
    prompt = build_lesson_prompt(chunk_title, chunk_content)
    prompt_id = UUID.uuid4() |> to_string()

    envelope = %{
      "event" => "llm.prompt.submit",
      "event_id" => UUID.uuid4() |> to_string(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_terrain",
      "source_node" => get_node_name(),
      "triggered_by" => "lesson_handler",
      "schema_version" => "1.0",
      "source_metadata" => %{
        "source_domain" => "lesson_generation",
        "chunk_id" => chunk_id
      },
      "payload" => %{
        "text" => prompt,
        "prompt_id" => prompt_id,
        "context" => chunk_title
      }
    }

    case get_connection() do
      {:ok, conn} ->
        case Gnat.pub(conn, "llm.prompt.submit", Jason.encode!(envelope)) do
          :ok ->
            Logger.debug("Submitted LLM request for lesson generation: #{chunk_id}")
            :ok

          {:error, reason} ->
            Logger.error("Failed to submit LLM request: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, _} ->
        Logger.warning("NATS unavailable for LLM request")
        {:error, :nats_unavailable}
    end
  end

  @doc """
  Parse LLM text response with labeled fields.

  Expects format with single-line fields like TITLE:, EXTERNAL_LINK:, etc.
  EXPLANATION field may span multiple lines.
  Returns attrs map ready for LessonStore.store_lesson/1.
  """
  def parse_llm_text(text) do
    lines = String.split(text, "\n")

    extract = fn prefix ->
      Enum.find_value(lines, "", fn line ->
        if String.starts_with?(line, "#{prefix}:") do
          String.slice(line, String.length("#{prefix}: "), String.length(line)) |> String.trim()
        end
      end)
    end

    # Multi-line EXPLANATION — capture everything from "EXPLANATION:" to next field
    explanation =
      case Regex.run(~r/EXPLANATION:\s*(.*?)(?=\n[A-Z_]+:|$)/s, text) do
        [_, captured] -> String.trim(captured)
        _ -> extract.("EXPLANATION")
      end

    correct_index =
      case extract.("CORRECT_OPTION") do
        "1" -> 0
        "2" -> 1
        "3" -> 2
        "4" -> 3
        _ -> 0
      end

    npc_answer = fn key ->
      case extract.(key) do
        "1" -> 0
        "2" -> 1
        "3" -> 2
        "4" -> 3
        _ -> 1
      end
    end

    quiz_question = extract.("QUIZ_QUESTION")
    quiz_options = [
      extract.("OPTION_1"),
      extract.("OPTION_2"),
      extract.("OPTION_3"),
      extract.("OPTION_4")
    ]

    %{
      "title" => extract.("TITLE"),
      "explanation" => explanation,
      "external_link" => extract.("EXTERNAL_LINK"),
      "quiz_question" => quiz_question,
      "quiz_options" => quiz_options,
      "quiz_correct_index" => correct_index,
      "quiz_questions" => [
        %{
          "question" => quiz_question,
          "options" => quiz_options,
          "correct_index" => correct_index,
          "difficulty" => 2
        }
      ],
      "host_intro" => extract.("HOST_INTRO"),
      "host_correct" => extract.("HOST_CORRECT"),
      "host_wrong" => extract.("HOST_WRONG"),
      "npc_players" => [
        %{"name" => extract.("NPC_1_NAME"), "answer_index" => npc_answer.("NPC_1_ANSWER")},
        %{"name" => extract.("NPC_2_NAME"), "answer_index" => npc_answer.("NPC_2_ANSWER")}
      ]
    }
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
      "quiz_questions" => [
        %{
          "question" => "Which statement about #{chunk_title} is most accurate?",
          "options" => [
            "It is a core concept with practical applications",
            "It is rarely used in production code",
            "It only applies to advanced use cases",
            "It is specific to functional programming only"
          ],
          "correct_index" => 0,
          "difficulty" => 2
        }
      ],
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
          "quiz_questions" => lesson.quiz_questions || [],
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
          "quiz_questions" => [
            %{
              "question" => "Which statement about #{chunk_title} is most accurate?",
              "options" => [
                "It is a core concept with practical applications",
                "It is rarely used in production code",
                "It only applies to advanced use cases",
                "It is specific to functional programming only"
              ],
              "correct_index" => 0,
              "difficulty" => 2
            }
          ],
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
