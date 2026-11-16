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

  @chapter_dir Path.expand("../../priv/story", __DIR__)
  @chapter_paths Path.wildcard(Path.join(@chapter_dir, "chapter_*.json"))
  for path <- @chapter_paths, do: @external_resource(path)

  @ordered_chapters Enum.map(@chapter_paths, &(&1 |> File.read!() |> Jason.decode!()))
  @chapter Enum.find(@ordered_chapters, &(&1["id"] == "ch1")) || hd(@ordered_chapters)

  # 4 is cold, unassisted retrieval. A choice on the page is cued by its options, so a right
  # choice earns 3; the gate asks the card plainly and earns 4.
  @knew 4
  @missed 2
  @recovered 3
  @failed_gate 1
  @gate_size 3
  @redeem_after 2

  @doc "The first chapter, where a new story starts."
  def chapter, do: @chapter

  @doc "A chapter by its id, or nil when no such chapter exists."
  def chapter(id) when is_binary(id), do: Enum.find(@ordered_chapters, &(&1["id"] == id))

  @doc "The chapter after `id`, in reading order, or nil at the end of the season."
  def next_chapter(id) when is_binary(id) do
    ids = Enum.map(@ordered_chapters, & &1["id"])

    case Enum.find_index(ids, &(&1 == id)) do
      nil -> nil
      i -> Enum.at(@ordered_chapters, i + 1)
    end
  end

  def next_chapter(_id), do: nil

  @doc "Every published chapter, in reading order."
  def chapters, do: @ordered_chapters

  @doc "Progress for a story that has not started."
  def start, do: start(@chapter["id"])

  @doc "Progress at the first scene of a named chapter."
  def start(chapter_id) when is_binary(chapter_id) do
    ch = chapter(chapter_id) || @chapter

    %{
      chapter: ch["id"],
      scene_id: ch["start"],
      facts: %{},
      log: [],
      chosen_on: nil,
      last_outcome: nil
    }
  end

  def scene(id), do: Map.get(@chapter["scenes"], id)

  @doc "A scene in a named chapter, or nil."
  def scene(chapter_id, id) do
    case chapter(chapter_id) do
      nil -> nil
      ch -> Map.get(ch["scenes"], id)
    end
  end

  @doc "The page's choice options in a day's order, each carrying the index the bot understands."
  def choice_options(choice, scene_id, %Date{} = date) do
    for i <- shuffle(length(choice["options"]), scene_id, date) do
      option = Enum.at(choice["options"], i)
      %{"label" => option["label"], "index" => i}
    end
  end

  @doc """
  What the page draws now: `{:scene, scene}`, `{:gate, outcome}`, `{:redeem, page}`,
  `{:done, outcome}` or `{:end, scene}`. `scene` carries the echoes the world's facts unlock.

  A redemption comes before the current scene and does not spend it: it is a second chance at a
  scene she got wrong, offered once the story has moved two scenes past it (or at the chapter's
  end), at most one attempt a day.
  """
  def today(progress, %Date{} = date) do
    ch = chapter(progress.chapter) || @chapter
    scene = scene(ch["id"], progress.scene_id)
    outcome = progress.last_outcome || %{}
    redeem = due_redemption(progress, date)

    cond do
      outcome["status"] == "gate_open" ->
        {:gate, public(outcome)}

      redeem ->
        {:redeem, redeem_view(ch["id"], redeem, date)}

      outcome["status"] == "passed" and not Map.has_key?(outcome, "redeem") ->
        {:done, public(outcome)}

      scene["end"] ->
        {:end,
         view(ch["id"], progress.scene_id, scene, progress.facts, date)
         |> Map.put("next_chapter", next_chapter_stub(ch["id"]))
         |> Map.put("lesson", ch["lesson"])}

      true ->
        {:scene, view(ch["id"], progress.scene_id, scene, progress.facts, date)}
    end
  end

  @doc """
  Turn the page after an outcome. The next scene is not gated by the clock. At the end of a
  chapter, a second press opens the chapter that follows (facts travel; the path starts again).
  """
  def next(progress, %Date{} = date) do
    case {progress.last_outcome, scene(progress.chapter, progress.scene_id)} do
      {%{"status" => "gate_open"}, _} ->
        {:error, :gate_open}

      {%{"status" => "passed"}, _} ->
        {:ok, %{progress | chosen_on: nil, last_outcome: nil}}

      {nil, %{"end" => true}} ->
        begin_next(progress, date)

      _ ->
        {:error, :not_done}
    end
  end

  defp begin_next(progress, _date) do
    case next_chapter(progress.chapter) do
      nil ->
        {:error, :no_next_chapter}

      ch ->
        {:ok,
         %{
           progress
           | chapter: ch["id"],
             scene_id: ch["start"],
             log: [],
             chosen_on: nil,
             last_outcome: nil
         }}
    end
  end

  defp next_chapter_stub(id) do
    case next_chapter(id) do
      nil -> nil
      ch -> %{"id" => ch["id"], "title" => ch["title"]}
    end
  end

  @doc """
  The scene with only the echoes its facts have earned, and choices without their answers.
  """
  def view(_chapter_id, scene_id, scene, facts, %Date{} = date) do
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
            "options" => choice_options(choice, scene_id, date)
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
    ch = chapter(progress.chapter) || @chapter

    with :ok <- may_choose(progress, scene_id, date),
         %{"choice" => choice} <- scene(ch["id"], scene_id),
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
        right_choice(progress, option, card, facts, log, date, deck_cards)
      else
        wrong_choice(progress, option, card, facts, log, date, deck_cards)
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :no_such_option}
    end
  end

  defp right_choice(progress, option, card, facts, log, date, deck_cards) do
    progress = %{
      progress
      | scene_id: option["next"],
        facts: facts,
        log: log,
        chosen_on: date,
        last_outcome: %{
          "status" => "passed",
          "text" => restate(option["outcome"], card, deck_cards.(card["deck"])),
          "correct" => true
        }
    }

    {:ok, progress, {card, @recovered}}
  end

  defp wrong_choice(progress, option, card, facts, log, date, deck_cards) do
    case gate(card, deck_cards.(card["deck"]), date) do
      nil ->
        {:error, :missing_card}

      gate ->
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
  end

  @doc "Answer the recall gate opened by a wrong choice."
  def answer_gate(progress, index, %Date{} = date) do
    outcome = progress.last_outcome || %{}

    with true <- outcome["status"] == "gate_open",
         %{"choice" => choice} <- scene(progress.chapter, progress.scene_id),
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
         }, {card, @knew}}
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
         %{"choice" => choice} <- scene(progress.chapter, scene_id),
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
    ch = chapter(progress.chapter) || @chapter

    for e <- progress.log do
      scene = scene(ch["id"], e["scene"]) || %{}

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
      at_end = (scene(progress.chapter, progress.scene_id) || %{})["end"] == true

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

  defp redeem_view(chapter_id, scene_id, date) do
    scene = scene(chapter_id, scene_id)
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
    case Enum.find(cards, &(&1.front == card["front"])) do
      nil ->
        nil

      %{back: right} ->
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
  end

  # A right choice is cued by its options, so the fact is said again after the outcome: the
  # learner sees the card's question and its answer together, once, and the story moves on.
  defp restate(text, card, cards) do
    case Enum.find(cards, &(&1.front == card["front"])) do
      %{back: back} when is_binary(back) -> text <> "\n\n" <> card["front"] <> "\n" <> back
      _ -> text
    end
  end

  defp public(outcome) do
    case outcome["gate"] do
      nil -> Map.delete(outcome, "gate")
      gate -> Map.put(outcome, "gate", Map.delete(gate, "answer"))
    end
  end
end
