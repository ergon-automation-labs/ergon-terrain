defmodule BotArmyTerrain.Handlers.GameGenerationHandler do
  @moduledoc """
  Builds LLM prompts for game generation and publishes them to the LLM service.
  Handles two phases: game generation and dojo lesson generation.
  """

  require Logger
  alias BotArmyRuntime.NATS.Connection

  @doc """
  Generate game structure (questions, branching, difficulty, bonuses).
  Publishes prompt to llm.prompt.submit with phase="game" in source_metadata.
  """
  def generate_game(track_id, lessons) do
    prompt = build_game_prompt(lessons)
    publish_to_llm(track_id, "game", prompt)
  end

  @doc """
  Generate Dojo lessons (study guides, key concepts, practice problems).
  Publishes prompt to llm.prompt.submit with phase="dojo" in source_metadata.
  """
  def generate_dojo(track_id, lessons) do
    prompt = build_dojo_prompt(lessons)
    publish_to_llm(track_id, "dojo", prompt)
  end

  defp build_game_prompt(lessons) do
    lesson_text =
      lessons
      |> Enum.map(fn lesson ->
        """
        Lesson: #{lesson.title}
        Content: #{lesson.explanation}
        Quiz Question: #{lesson.quiz_question || "N/A"}
        """
      end)
      |> Enum.join("\n\n")

    """
    You are a quiz game designer. Based on these lessons, generate a game structure.
    Return ONLY valid JSON matching this exact structure:

    {
      "sections": [
        {
          "lesson_title": "...",
          "difficulty": 1,
          "questions": [
            {
              "id": "q1",
              "question": "...",
              "options": ["option1", "option2", "option3", "option4"],
              "correct_index": 0,
              "points": 100,
              "branch_on_fail": "remedial_q1"
            }
          ],
          "remedial": [
            {
              "id": "remedial_q1",
              "question": "...",
              "options": ["option1", "option2", "option3", "option4"],
              "correct_index": 0,
              "points": 50
            }
          ],
          "bonus": {
            "id": "bonus1",
            "title": "Challenge Question",
            "question": "...",
            "options": ["option1", "option2", "option3", "option4"],
            "correct_index": 0,
            "points": 500
          }
        }
      ]
    }

    LESSONS:
    #{lesson_text}

    Design questions that:
    - Progress from easy to hard
    - Branch to remedial questions on wrong answers
    - Include bonus challenges for mastery
    - Vary the correct answer position
    - Test deep understanding, not just recall
    """
  end

  defp build_dojo_prompt(lessons) do
    lesson_text =
      lessons
      |> Enum.map(fn lesson ->
        """
        #{lesson.title}: #{lesson.explanation}
        """
      end)
      |> Enum.join("\n\n")

    """
    You are an educational content designer. Create Dojo (self-study) lessons.
    Return ONLY valid JSON matching this exact structure:

    {
      "lessons": [
        {
          "lesson_title": "...",
          "study_guide": "2-3 paragraphs of study material explaining the core concepts",
          "key_concepts": ["concept1", "concept2", "concept3"],
          "practice_problems": [
            {"question": "...", "answer": "..."},
            {"question": "...", "answer": "..."}
          ],
          "tips": ["tip1", "tip2", "tip3"]
        }
      ]
    }

    LESSON CONTENT:
    #{lesson_text}

    For each lesson, create:
    - Study guide: 2-3 paragraphs of clear, accessible explanation
    - Key concepts: 3-5 main takeaways
    - Practice problems: 3-4 problems with concise answers
    - Tips: 3-4 practical tips or gotchas to remember
    """
  end

  defp publish_to_llm(track_id, phase, prompt) do
    case Connection.get_connection() do
      {:ok, conn} ->
        envelope = %{
          "event" => "llm.prompt.submit",
          "event_id" => Elixir.UUID.uuid4(),
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "source" => "bot_army_terrain",
          "source_node" => :inet.gethostname() |> elem(1) |> to_string(),
          "triggered_by" => "game_generation_handler",
          "schema_version" => "1.0",
          "source_metadata" => %{
            "source_domain" => "game_generation",
            "track_id" => track_id,
            "phase" => phase
          },
          "payload" => %{
            "text" => prompt,
            "prompt_id" => Elixir.UUID.uuid4(),
            "context" => "game_#{phase}_generation"
          }
        }

        case Gnat.pub(conn, "llm.prompt.submit", Jason.encode!(envelope)) do
          :ok ->
            Logger.info("Terrain: published LLM prompt for track #{track_id}, phase #{phase}")
            :ok

          {:error, reason} ->
            Logger.error(
              "Terrain: failed to publish LLM prompt for track #{track_id}: #{inspect(reason)}"
            )

            {:error, reason}
        end

      {:error, _} ->
        Logger.error("Terrain: NATS unavailable for game generation")
        {:error, :nats_unavailable}
    end
  end
end
