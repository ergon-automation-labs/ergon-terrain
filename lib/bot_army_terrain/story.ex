defmodule BotArmyTerrain.Story do
  @moduledoc """
  The morning story: a choose-your-own-adventure whose every choice is a quiz.

  One scene per household day. A scene ends on a choice that is a card in disguise. The right
  choice moves the story on. A wrong choice costs something in the story (a fact the world
  remembers) and opens a **recall gate**: the card's question asked plainly, its answer among
  other answers from the same deck. Pass the gate and the story moves on; fail it and the same
  scene waits tomorrow. Nothing advances without the fact being recalled.

  Pure: the chapter is compiled in from `priv/story/`, progress is a plain map, and the
  handler does the reads and writes. Grades are returned as `{card_ref, quality}` for the
  handler to send through the normal review path.
  """

  @chapter_path Path.join([__DIR__, "..", "..", "priv", "story", "chapter_01.json"])
  @external_resource @chapter_path
  @chapter @chapter_path |> File.read!() |> Jason.decode!()

  @knew 4
  @missed 2
  @recovered 3
  @failed_gate 1
  @gate_size 3

  def chapter, do: @chapter

  @doc "Progress for a story that has not started."
  def start do
    %{
      chapter: @chapter["id"],
      scene_id: @chapter["start"],
      facts: %{},
      log: [],
      chosen_on: nil,
      last_outcome: nil
    }
  end

  def scene(id), do: Map.get(@chapter["scenes"], id)

  @doc """
  What the page draws this morning: `{:scene, scene}`, `{:gate, outcome}`, `{:done, outcome}`
  or `{:end, scene}`. `scene` carries the echoes the world's facts unlock.
  """
  def today(progress, %Date{} = date) do
    scene = scene(progress.scene_id)
    outcome = progress.last_outcome || %{}

    cond do
      progress.chosen_on == date and outcome["status"] == "gate_open" -> {:gate, public(outcome)}
      progress.chosen_on == date -> {:done, public(outcome)}
      scene["end"] -> {:end, view(scene, progress.facts)}
      true -> {:scene, view(scene, progress.facts)}
    end
  end

  @doc """
  The scene with only the echoes its facts have earned, and choices without their answers.
  """
  def view(scene, facts) do
    echoes =
      for %{"fact" => fact, "text" => text} <- Map.get(scene, "echoes", []),
          Map.get(facts, fact),
          do: text

    choice =
      case scene["choice"] do
        nil ->
          nil

        choice ->
          %{
            "prompt" => choice["prompt"],
            "options" => Enum.map(choice["options"], &Map.take(&1, ["label"]))
          }
      end

    scene
    |> Map.take(["title", "text", "ritual", "terms", "end"])
    |> Map.merge(%{"echoes" => echoes, "choice" => choice})
  end

  @doc """
  Make the scene's choice. `deck_cards` is `fn deck -> [%{front: _, back: _}] end`: the
  deck's cards, which give the gate its right answer and its distractors. Returns `{:ok, progress, grade}` with `grade` as
  `{%{"deck", "front"}, quality}`, or `{:error, reason}`.
  """
  def choose(progress, scene_id, index, %Date{} = date, deck_cards) do
    with :ok <- may_choose(progress, scene_id, date),
         %{"choice" => choice} <- scene(scene_id),
         %{} = option <- Enum.at(choice["options"], index) do
      card = choice["card"]
      facts = Map.merge(progress.facts, Map.get(option, "set", %{}))
      log = progress.log ++ [%{"on" => Date.to_iso8601(date), "scene" => scene_id, "pick" => index}]

      if option["correct"] do
        progress = %{
          progress
          | scene_id: option["next"],
            facts: facts,
            log: log,
            chosen_on: date,
            last_outcome: %{"status" => "passed", "text" => option["outcome"], "correct" => true}
        }

        {:ok, progress, {card, @knew}}
      else
        gate = gate(card, deck_cards.(card["deck"]), date)

        progress = %{
          progress
          | facts: facts,
            log: log,
            chosen_on: date,
            last_outcome: %{
              "status" => "gate_open",
              "text" => option["outcome"],
              "correct" => false,
              "gate" => gate
            }
        }

        {:ok, progress, {card, @missed}}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :no_such_option}
    end
  end

  @doc "Answer the recall gate opened by a wrong choice."
  def answer_gate(progress, index, %Date{} = date) do
    outcome = progress.last_outcome || %{}

    with true <- progress.chosen_on == date and outcome["status"] == "gate_open",
         %{"choice" => choice} <- scene(progress.scene_id),
         gate when is_map(gate) <- outcome["gate"],
         true <- is_integer(index) and index >= 0 and index < length(gate["options"]) do
      card = choice["card"]

      if index == gate["answer"] do
        right = Enum.find(choice["options"], & &1["correct"])

        {:ok,
         %{
           progress
           | scene_id: right["next"],
             last_outcome: %{
               "status" => "passed",
               "correct" => true,
               "text" =>
                 "**Recalled.** The System grudgingly lets you through. *Next time, get it the first time.*\n\n" <>
                   right["outcome"]
             }
         }, {card, @recovered}}
      else
        {:ok,
         %{
           progress
           | last_outcome: %{
               "status" => "repeat",
               "correct" => false,
               "text" =>
                 "!!Wrong again.!! The answer was: " <>
                   Enum.at(gate["options"], gate["answer"]) <>
                   "\n\n**This scene waits for you tomorrow.** The System *does not* move on without you knowing this."
             }
         }, {card, @failed_gate}}
      end
    else
      _ -> {:error, :no_gate}
    end
  end

  defp may_choose(%{chosen_on: date}, _scene_id, date), do: {:error, :already_chosen}
  defp may_choose(%{scene_id: scene_id}, scene_id, _date), do: :ok
  defp may_choose(_progress, _scene_id, _date), do: {:error, :stale_scene}

  defp gate(card, cards, date) do
    right =
      Enum.find_value(cards, "(the card is missing from its deck)", fn c ->
        if c.front == card["front"], do: c.back
      end)

    others = cards |> Enum.map(& &1.back) |> Enum.reject(&(&1 == right)) |> Enum.uniq()
    seed = Date.to_gregorian_days(date)

    distractors =
      others
      |> Enum.sort_by(&:erlang.phash2({&1, seed}))
      |> Enum.take(@gate_size - 1)

    options = Enum.sort_by([right | distractors], &:erlang.phash2({&1, seed + 1}))

    %{
      "question" => card["front"],
      "options" => options,
      "answer" => Enum.find_index(options, &(&1 == right))
    }
  end

  defp public(outcome) do
    case outcome["gate"] do
      nil -> Map.delete(outcome, "gate")
      gate -> Map.put(outcome, "gate", Map.delete(gate, "answer"))
    end
  end
end
