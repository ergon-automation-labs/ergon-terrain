defmodule BotArmyTerrain.Story do
  @moduledoc """
  The morning story: a choose-your-own-adventure whose every choice is a quiz.

  A scene ends on a choice that is a card in disguise. The right choice moves the story on. A
  wrong choice costs something in the story (a fact the world remembers) and opens a **recall
  gate**: the card's question asked plainly, its answer among other answers from the same deck.
  Pass the gate and the story moves on; fail it and the scene stays open to try again. Nothing
  advances without the fact being recalled. There is no day lock: the next scene is one press
  away (`next/2`), so a sitting can be as long or as short as she wants.

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
  @redeem_after 2

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
  What the page draws now: `{:scene, scene}`, `{:gate, outcome}`, `{:redeem, page}`,
  `{:done, outcome}` or `{:end, scene}`. `scene` carries the echoes the world's facts unlock.

  A redemption comes before the current scene and does not spend it: it is a second chance at a
  scene she got wrong, offered once the story has moved two scenes past it (or at the chapter's
  end), at most one attempt a day.
  """
  def today(progress, %Date{} = date) do
    scene = scene(progress.scene_id)
    outcome = progress.last_outcome || %{}
    redeem = due_redemption(progress, date)

    cond do
      outcome["status"] == "gate_open" ->
        {:gate, public(outcome)}

      redeem ->
        {:redeem, redeem_view(redeem, date)}

      outcome["status"] == "passed" and not Map.has_key?(outcome, "redeem") ->
        {:done, public(outcome)}

      scene["end"] ->
        {:end, view(scene, progress.facts)}

      true ->
        {:scene, view(scene, progress.facts)}
    end
  end

  @doc """
  Turn the page, without waiting for tomorrow. Only a passed scene has a next page; a gate
  still open must be answered first, and a scene she has not finished has nowhere to go.
  """
  def next(%{last_outcome: %{"status" => "gate_open"}}, _date), do: {:error, :gate_open}

  def next(%{last_outcome: %{"status" => "passed"}} = progress, _date),
    do: {:ok, %{progress | chosen_on: nil, last_outcome: nil}}

  def next(_progress, _date), do: {:error, :not_done}

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

      log =
        progress.log ++
          [
            entry(date, "choice", scene_id, %{
              "pick" => index,
              "correct" => option["correct"] == true
            })
          ]

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

    with true <- outcome["status"] == "gate_open",
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
             log: progress.log ++ [entry(date, "gate", progress.scene_id, %{"correct" => true})],
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
           | log: progress.log ++ [entry(date, "gate", progress.scene_id, %{"correct" => false})],
             last_outcome: %{
               "status" => "repeat",
               "correct" => false,
               "text" =>
                 "!!Wrong again.!! The answer was: " <>
                   Enum.at(gate["options"], gate["answer"]) <>
                   "\n\n**This scene waits for you.** The System *does not* move on without you knowing this."
             }
         }, {card, @failed_gate}}
      end
    else
      _ -> {:error, :no_gate}
    end
  end

  @doc """
  Make a redemption's choice. `index` is the position on the page, whose order is shuffled by
  the day so a remembered position is not a remembered fact. Right: the scene's penalties are
  undone and its reward granted (grade 4). Wrong: it waits two more scenes (grade 2).
  """
  def redeem(progress, scene_id, index, %Date{} = date) do
    with ^scene_id <- due_redemption(progress, date),
         %{"choice" => choice} <- scene(scene_id),
         original when is_integer(original) <-
           Enum.at(shuffle(length(choice["options"]), scene_id, date), index) do
      option = Enum.at(choice["options"], original)
      correct = option["correct"] == true

      log =
        progress.log ++
          [entry(date, "redeem", scene_id, %{"pick" => original, "correct" => correct})]

      {facts, note, quality} = redeem_result(progress.facts, choice, option, correct)

      last =
        Map.put(progress.last_outcome || %{}, "redeem", %{
          "on" => Date.to_iso8601(date),
          "text" => note
        })

      {:ok, %{progress | facts: facts, log: log, last_outcome: last}, {choice["card"], quality}}
    else
      _ -> {:error, :no_redemption}
    end
  end

  defp redeem_result(facts, choice, option, true) do
    penalties =
      for o <- choice["options"], !o["correct"], key <- Map.keys(Map.get(o, "set", %{})), do: key

    {facts |> Map.drop(penalties) |> Map.merge(Map.get(option, "set", %{})),
     "**Redeemed.** *You remembered.* The ship remembers too — the old damage is undone.\n\n" <>
       option["outcome"], @knew}
  end

  defp redeem_result(facts, _choice, _option, false) do
    {facts,
     "!!Not yet.!! The System files it away, *unimpressed*. **It'll be back in two scenes.**",
     @missed}
  end

  @doc "A redemption note made today, to show above the morning's page."
  def redeem_note(progress, %Date{} = date) do
    case progress.last_outcome do
      %{"redeem" => %{"on" => on, "text" => text}} -> if on == Date.to_iso8601(date), do: text
      _ -> nil
    end
  end

  @doc "The path so far: one line per choice, gate and redemption, oldest first."
  def path(progress) do
    for e <- progress.log do
      scene = scene(e["scene"]) || %{}

      label =
        with i when is_integer(i) <- e["pick"],
             %{"choice" => c} <- scene,
             %{"label" => l} <- Enum.at(c["options"], i),
             do: l,
             else: (_ -> nil)

      %{
        "on" => e["on"],
        "kind" => e["kind"],
        "scene" => e["scene"],
        "title" => scene["title"],
        "choice" => label,
        "correct" => e["correct"]
      }
    end
  end

  @doc "The scene due for a second chance this morning, or nil."
  def due_redemption(progress, %Date{} = date) do
    today = Date.to_iso8601(date)
    log = progress.log

    if Enum.any?(log, &(&1["kind"] == "redeem" and &1["on"] == today)) do
      nil
    else
      at_end = (scene(progress.scene_id) || %{})["end"] == true

      log
      |> Enum.filter(&(&1["kind"] == "choice" and &1["correct"] == false))
      |> Enum.map(& &1["scene"])
      |> Enum.uniq()
      |> Enum.reject(&(&1 == progress.scene_id or redeemed?(log, &1)))
      |> Enum.find(&(at_end or scenes_since(log, &1) >= @redeem_after))
    end
  end

  defp redeemed?(log, scene_id),
    do: Enum.any?(log, &(&1["kind"] == "redeem" and &1["scene"] == scene_id and &1["correct"]))

  defp scenes_since(log, scene_id) do
    anchor =
      log
      |> Enum.with_index()
      |> Enum.filter(fn {e, _} -> e["scene"] == scene_id end)
      |> List.last()
      |> elem(1)

    log
    |> Enum.drop(anchor + 1)
    |> Enum.filter(&(&1["kind"] == "choice" and &1["scene"] != scene_id))
    |> Enum.map(& &1["scene"])
    |> Enum.uniq()
    |> length()
  end

  defp redeem_view(scene_id, date) do
    scene = scene(scene_id)
    options = scene["choice"]["options"]

    %{
      "scene_id" => scene_id,
      "title" => "Second chance — " <> scene["title"],
      "text" =>
        "**The System is feeling generous.** *Suspiciously* generous. It rewinds the tape to a moment you fumbled: **" <>
          scene["title"] <> "**. Show it you learned.",
      "terms" => scene["terms"],
      "choice" => %{
        "prompt" => scene["choice"]["prompt"],
        "options" =>
          for(
            i <- shuffle(length(options), scene_id, date),
            do: Map.take(Enum.at(options, i), ["label"])
          )
      }
    }
  end

  defp shuffle(n, scene_id, date) do
    seed = Date.to_gregorian_days(date)
    order = Enum.sort_by(0..(n - 1), &:erlang.phash2({&1, seed, scene_id}))
    if order == Enum.to_list(0..(n - 1)), do: Enum.reverse(order), else: order
  end

  defp entry(date, kind, scene_id, extra),
    do: Map.merge(%{"on" => Date.to_iso8601(date), "kind" => kind, "scene" => scene_id}, extra)

  defp may_choose(%{scene_id: scene_id} = progress, scene_id, date) do
    status = (progress.last_outcome || %{})["status"]

    cond do
      status == "gate_open" -> {:error, :gate_open}
      status == "passed" and progress.chosen_on == date -> {:error, :already_chosen}
      true -> :ok
    end
  end

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
