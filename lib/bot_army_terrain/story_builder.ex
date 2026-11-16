defmodule BotArmyTerrain.StoryBuilder do
  @moduledoc """
  Builds a playable chapter from a plan and the deck's cards.

  The plan owns the prose, the lesson, and the beats. The builder owns the wiring that is
  easy to get wrong by hand: it resolves each scene's card, pulls the card's answer into the
  correct option, points every choice at the next scene, adds the end scene, and refuses a
  graph that cannot be played (missing target, unreachable end, duplicate id, no card).

  A chapter is data; this is the compiler from a human plan to that data.
  """

  @min_scenes 4
  @max_scenes 8

  @doc """
  `plan` is a chapter plan; `cards` are card rows (`front`, `back`, `deck`).

  Returns `{:ok, chapter}` or `{:error, reasons}` where reasons are short strings for an
  operator (never shown to the learner).
  """
  def build(%{} = plan, cards) when is_list(cards) do
    with :ok <- check_plan(plan),
         {:ok, scenes} <- build_scenes(plan, cards),
         :ok <- check_graph(plan, scenes) do
      {:ok,
       %{
         "id" => plan["id"],
         "title" => plan["title"],
         "start" => plan["start"],
         "scenes" => scenes
       }}
    end
  end

  def build(_plan, _cards), do: {:error, ["the plan must be an object and the cards a list"]}

  defp check_plan(plan) do
    missing = plan_missing(plan)

    cond do
      missing != [] ->
        {:error, missing}

      length(plan["scenes"]) < @min_scenes ->
        {:error, ["a chapter needs at least #{@min_scenes} scenes"]}

      length(plan["scenes"]) > @max_scenes ->
        {:error, ["a chapter holds at most #{@max_scenes} scenes"]}

      not end_ready?(plan) ->
        {:error, ["the end needs a title and text"]}

      true ->
        :ok
    end
  end

  defp plan_missing(plan) do
    missing =
      for key <- ~w(id title start), not present?(plan[key]), do: "the plan is missing #{key}"

    missing =
      if is_list(plan["scenes"]), do: missing, else: missing ++ ["the plan needs a scenes list"]

    if is_map(plan["end"]), do: missing, else: missing ++ ["the plan needs an end object"]
  end

  defp end_ready?(plan), do: present?(plan["end"]["title"]) and present?(plan["end"]["text"])

  defp build_scenes(plan, cards) do
    plan["scenes"]
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}}, &add_scene(&1, &2, plan, cards))
    |> case do
      {:ok, scenes} -> {:ok, Map.put(scenes, "end", end_scene(plan))}
      other -> other
    end
  end

  defp add_scene({spec, index}, {:ok, acc}, plan, cards) do
    case build_scene(plan, spec, index, cards) do
      {:ok, id, scene} ->
        if Map.has_key?(acc, id),
          do: {:halt, {:error, ["scene id #{id} is used twice"]}},
          else: {:cont, {:ok, Map.put(acc, id, scene)}}

      {:error, reasons} ->
        {:halt, {:error, reasons}}
    end
  end

  defp build_scene(plan, spec, index, cards) do
    with :ok <- check_scene(plan, spec, index),
         {:ok, card} <- find_card(spec, cards, index) do
      answer = plain(card["back"])

      if answer == "" do
        {:error, ["the card for scene #{spec["id"]} has no answer"]}
      else
        {:ok, spec["id"], scene(plan, spec, index, card, answer)}
      end
    end
  end

  defp check_scene(plan, spec, index) do
    id = spec["id"] || index + 1

    cond do
      not present?(spec["id"]) ->
        {:error, ["scene #{id} has no id"]}

      not present?(spec["card"]) ->
        {:error, ["scene #{id} names no card"]}

      not present?(spec["right"]) or not present?(spec["wrong"]) ->
        {:error, ["scene #{id} needs a right and a wrong outcome"]}

      not present?(spec["wrong_label"]) ->
        {:error, ["scene #{id} needs a wrong_label for its second button"]}

      not present?(spec["deck"] || plan["deck"]) ->
        {:error, ["scene #{id} names no deck (add deck to the plan)"]}

      true ->
        :ok
    end
  end

  defp find_card(spec, cards, index) do
    case Enum.find(cards, &(&1["front"] == spec["card"])) do
      nil ->
        {:error,
         [
           "scene #{spec["id"] || index + 1} tests a card that is not in the deck: #{spec["card"]}"
         ]}

      card ->
        {:ok, card}
    end
  end

  defp scene(plan, spec, index, card, answer) do
    next = next_id(plan, index)
    deck = card["deck"] || spec["deck"] || plan["deck"]
    options = options(spec, answer, next, index)

    %{
      "title" => spec["title"],
      "text" => spec["text"],
      "terms" => %{},
      "echoes" => spec["echoes"] || [],
      "ritual" => spec["ritual"],
      "choice" => %{
        "prompt" => spec["prompt"] || "Which answer do you give?",
        "card" => %{"deck" => deck, "front" => card["front"]},
        "options" => options
      }
    }
    |> drop_nil()
  end

  # Alternate the authored order so both positions get used; the page shuffles again per day.
  defp options(spec, answer, next, index) do
    right = %{
      "label" => answer_label(answer),
      "correct" => true,
      "next" => next,
      "outcome" => spec["right"],
      "set" => spec["set"] || %{}
    }

    wrong = %{
      "label" => spec["wrong_label"],
      "correct" => false,
      "next" => next,
      "outcome" => spec["wrong"],
      "set" => spec["wrong_set"] || %{}
    }

    if rem(index, 2) == 0, do: [right, wrong], else: [wrong, right]
  end

  defp end_scene(plan) do
    %{
      "title" => plan["end"]["title"],
      "text" => plan["end"]["text"],
      "echoes" => plan["end"]["echoes"] || [],
      "ritual" => plan["end"]["ritual"],
      "end" => true
    }
    |> drop_nil()
  end

  defp check_graph(plan, scenes) do
    ids = Map.keys(scenes)
    start = plan["start"]

    cond do
      start not in ids -> {:error, ["the start scene #{inspect(start)} does not exist"]}
      length(ids) != length(Enum.uniq(ids)) -> {:error, ["scene ids must be unique"]}
      true -> check_reach(plan, scenes)
    end
  end

  defp check_reach(plan, scenes) do
    case walk(scenes, plan["start"], MapSet.new()) do
      {:ok, seen} ->
        if MapSet.member?(seen, "end"),
          do: :ok,
          else: {:error, ["the end is not reachable from #{plan["start"]}"]}

      {:error, reason} ->
        {:error, [reason]}
    end
  end

  defp walk(scenes, id, seen) do
    cond do
      MapSet.member?(seen, id) ->
        {:ok, seen}

      not Map.has_key?(scenes, id) ->
        {:error, "a choice points at a scene that does not exist: #{id}"}

      true ->
        scenes
        |> Map.fetch!(id)
        |> targets()
        |> Enum.reduce_while({:ok, MapSet.put(seen, id)}, &walk_target(&1, scenes, &2))
    end
  end

  defp walk_target(target, scenes, {:ok, seen}) do
    case walk(scenes, target, seen) do
      {:ok, next_seen} -> {:cont, {:ok, next_seen}}
      error -> {:halt, error}
    end
  end

  defp targets(%{"choice" => %{"options" => options}}), do: Enum.map(options, & &1["next"])
  defp targets(_scene), do: []

  defp next_id(plan, index) do
    case Enum.at(plan["scenes"], index + 1) do
      nil -> "end"
      next -> next["id"]
    end
  end

  defp answer_label(answer), do: answer |> first_sentence() |> plain()

  defp first_sentence(text) do
    case Regex.run(~r/^.*?[.!?](?:\s|$)/, text) do
      [sentence | _] -> sentence
      nil -> text
    end
  end

  @doc "The answer as a button label: no markdown marks, no runs of whitespace."
  def plain(text) when is_binary(text) do
    text
    |> String.replace(~r/!!|\*\*|\*|`|\[\[|\]\]/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  def plain(_text), do: ""

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp drop_nil(map), do: Map.reject(map, fn {_k, v} -> is_nil(v) end)
end
