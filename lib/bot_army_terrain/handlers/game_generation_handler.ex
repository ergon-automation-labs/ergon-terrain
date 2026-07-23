defmodule BotArmyTerrain.Handlers.GameGenerationHandler do
  @moduledoc """
  Builds LLM prompts for game generation and publishes them to the LLM service.
  Handles two phases: game generation and dojo lesson generation.
  """

  require Logger
  alias BotArmyLibraryRuntime.NATS.Connection

  @doc """
  Generate game structure (questions, branching, difficulty, bonuses).
  Publishes prompt to llm.prompt.submit with phase="game" in source_metadata.
  """
  def generate_game(tenant_id, user_id, track_id, lessons) do
    prompt = build_game_prompt(lessons)
    publish_to_llm(tenant_id, user_id, track_id, "game", prompt)
  end

  @doc """
  Generate Dojo lessons (study guides, key concepts, practice problems).
  Publishes prompt to llm.prompt.submit with phase="dojo" in source_metadata.
  """
  def generate_dojo(tenant_id, user_id, track_id, lessons) do
    prompt = build_dojo_prompt(lessons)
    publish_to_llm(tenant_id, user_id, track_id, "dojo", prompt)
  end

  defp build_game_prompt(lessons) do
    sampled_questions = sample_gameshow_questions(lessons)

    lesson_text =
      sampled_questions
      |> Enum.map(fn q ->
        """
        Lesson: #{q.lesson_title}
        Lesson Difficulty: #{difficulty_label(q.lesson_difficulty)}
        Question Difficulty: #{difficulty_label(q.difficulty)}
        Question: #{q.question}
        Options: #{Enum.join(q.options, " | ")}
        Correct Option Text: #{q.correct_option}
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

    Build the gameshow using this question bank.
    Each generation should feel slightly different:
    - Pull a varied subset of easy/intermediate/advanced questions
    - Keep answer choices plausible and avoid obvious throwaway distractors
    - Avoid giveaway wording like "always", "never", or obviously absurd options
    - Vary the correct answer position across generated questions

    Design questions that:
    - Progress from easy to hard
    - Branch to remedial questions on wrong answers
    - Include bonus challenges for mastery
    - Test deep understanding, not just recall
    """
  end

  defp build_dojo_prompt(lessons) do
    lesson_text =
      lessons
      |> Enum.map(fn lesson ->
        question_bank = lesson_question_bank_text(lesson)

        """
        #{lesson.title}: #{lesson.explanation}
        Difficulty: #{difficulty_label(lesson.difficulty)}
        Full Question Set:
        #{question_bank}
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
    Use the full question set for each lesson as learning signals (not a sampled subset).
    """
  end

  defp lesson_question_bank_text(lesson) do
    extract_question_pool_for_lesson(lesson)
    |> Enum.map(fn q ->
      """
      - Q (#{difficulty_label(q.difficulty)}): #{q.question}
        Options: #{Enum.join(q.options, " | ")}
        Correct: #{q.correct_option}
      """
    end)
    |> Enum.join("\n")
  end

  defp sample_gameshow_questions(lessons) do
    pool =
      lessons
      |> Enum.flat_map(&extract_question_pool_for_lesson/1)
      |> Enum.shuffle()

    total = length(pool)

    if total <= 6 do
      pool
    else
      target = min(total, max(8, div(length(lessons) * 3, 2)))
      pick_by_difficulty(pool, target)
    end
  end

  defp pick_by_difficulty(pool, target) do
    grouped = Enum.group_by(pool, & &1.difficulty)
    easy = Map.get(grouped, 1, []) |> Enum.shuffle()
    mid = Map.get(grouped, 2, []) |> Enum.shuffle()
    hard = Map.get(grouped, 3, []) |> Enum.shuffle()

    easy_target = min(length(easy), max(1, div(target * 4, 10)))
    mid_target = min(length(mid), max(1, div(target * 4, 10)))
    hard_target = min(length(hard), max(1, target - easy_target - mid_target))

    selected =
      take(easy, easy_target) ++
        take(mid, mid_target) ++
        take(hard, hard_target)

    if length(selected) >= target do
      selected |> Enum.take(target) |> Enum.shuffle()
    else
      already = MapSet.new(selected, &question_key/1)

      remainder =
        pool
        |> Enum.reject(fn q -> MapSet.member?(already, question_key(q)) end)
        |> Enum.shuffle()
        |> take(target - length(selected))

      (selected ++ remainder) |> Enum.shuffle()
    end
  end

  defp question_key(q), do: "#{q.lesson_title}|#{q.question}"

  defp take(_list, n) when n <= 0, do: []
  defp take(list, n), do: Enum.take(list, n)

  defp extract_question_pool_for_lesson(lesson) do
    source_questions =
      case lesson.quiz_questions do
        questions when is_list(questions) and questions != [] -> questions
        _ -> [legacy_question_map(lesson)]
      end

    source_questions
    |> Enum.map(&normalize_question(&1, lesson))
    |> Enum.reject(&is_nil/1)
  end

  defp legacy_question_map(lesson) do
    %{
      "question" => lesson.quiz_question,
      "options" => lesson.quiz_options || [],
      "correct_index" => lesson.quiz_correct_index,
      "difficulty" => lesson.difficulty
    }
  end

  defp normalize_question(question, lesson) do
    stem = get_q(question, "question")
    options = get_q(question, "options", [])
    correct_index = get_q(question, "correct_index")

    difficulty =
      normalize_difficulty(get_q(question, "difficulty", lesson.difficulty), lesson.difficulty)

    if is_binary(stem) and is_list(options) and is_integer(correct_index) and correct_index >= 0 and
         correct_index < length(options) do
      shuffled = shuffle_question_options(options, correct_index)

      %{
        lesson_title: lesson.title,
        lesson_difficulty: lesson.difficulty || 2,
        question: stem,
        options: shuffled.options,
        correct_option: shuffled.correct_option,
        difficulty: difficulty
      }
    else
      nil
    end
  end

  defp shuffle_question_options(options, correct_index) do
    tagged =
      options
      |> Enum.with_index()
      |> Enum.map(fn {opt, idx} -> %{option: opt, correct: idx == correct_index} end)
      |> Enum.shuffle()

    correct =
      tagged
      |> Enum.find(fn item -> item.correct end)
      |> Map.get(:option)

    %{options: Enum.map(tagged, & &1.option), correct_option: correct}
  end

  defp get_q(map, key, default \\ nil) do
    case map do
      %{} = m -> Map.get(m, key, Map.get(m, question_atom_key(key), default))
      _ -> default
    end
  end

  defp question_atom_key("question"), do: :question
  defp question_atom_key("options"), do: :options
  defp question_atom_key("correct_index"), do: :correct_index
  defp question_atom_key("difficulty"), do: :difficulty
  defp question_atom_key(_), do: nil

  defp normalize_difficulty(value, _fallback) when is_integer(value) do
    cond do
      value < 1 -> 1
      value > 3 -> 3
      true -> value
    end
  end

  defp normalize_difficulty("beginner", _fallback), do: 1
  defp normalize_difficulty("intermediate", _fallback), do: 2
  defp normalize_difficulty("advanced", _fallback), do: 3
  defp normalize_difficulty(_, fallback), do: fallback || 2

  defp difficulty_label(1), do: "beginner"
  defp difficulty_label(2), do: "intermediate"
  defp difficulty_label(3), do: "advanced"
  defp difficulty_label(_), do: "intermediate"

  defp publish_to_llm(tenant_id, user_id, track_id, phase, prompt) do
    case GenServer.call(Connection, :get_connection, 5_000) do
      {:ok, conn} ->
        envelope = %{
          "event" => "llm.prompt.submit",
          "event_id" => Elixir.UUID.uuid4(),
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "source" => "bot_army_terrain",
          "source_node" => :inet.gethostname() |> elem(1) |> to_string(),
          "triggered_by" => "game_generation_handler",
          "schema_version" => "1.0",
          "tenant_id" => tenant_id,
          "user_id" => user_id,
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
