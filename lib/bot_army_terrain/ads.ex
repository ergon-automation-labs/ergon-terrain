defmodule BotArmyTerrain.Ads do
  @moduledoc """
  The story's interstitials, chosen at a chapter boundary.

  A creative is a text ad first: a title, two short paragraphs that *show* why a lesson is
  useful, and one question with a blank where she supplies the connection. A `media` key may
  name a motion-comic enhancement, but the text is canonical and the page never depends on the
  video.

  Interstitials are not an ad network. There are two slots — the end of a chapter
  (`story_boundary`) and the first scene of the next (`chapter_start`, used for the recap) — one
  creative per boundary, no countdown, no urgency, and `ads_enabled: false` is absolute. A
  trailer for the next chapter is refused if it would leak any of that chapter's answers; a
  sponsor is refused until its lesson is at least two chapters old.
  """

  require Logger

  alias BotArmyTerrain.Story

  @creatives_dir Path.expand("../../priv/ads/creatives", __DIR__)
  @slot "story_boundary"
  @chapter_start_slot "chapter_start"
  @sponsor_min_age 2

  @doc "Whether interstitials are allowed at all. `false` is absolute."
  def enabled? do
    Application.get_env(:bot_army_terrain, :ads_enabled, true) != false
  end

  @doc """
  The one creative that may air at the end of `progress.chapter`, or nil.

  The read is local: a handful of JSON files, the already-cached chapter list, and string
  checks. No model, no render, no network.
  """
  def for_chapter(progress, _date) do
    if enabled?() do
      chapter_id = progress.chapter

      chapter_id
      |> candidates()
      |> Enum.find(&allowed?(&1, chapter_id))
      |> case do
        nil -> nil
        creative -> decorate(creative, chapter_id, "chapter_end:")
      end
    end
  end

  @doc """
  The one recap that may air when she opens `progress.chapter`, or nil.

  A recap is story, not inventory: it restates the lesson of the chapter she just finished, and
  it must not leak an answer from the chapter she is entering. It airs only on the chapter's
  first scene, so a reload mid-chapter cannot bring it back.
  """
  def for_scene(progress, _date) do
    if enabled?(), do: chapter_recap(progress)
  end

  defp chapter_recap(progress) do
    chapter = Story.chapter(progress.chapter)
    previous = previous_chapter(progress.chapter)

    if chapter && previous && progress.scene_id == chapter["start"] do
      recap_for(progress.chapter, previous, chapter)
    end
  end

  @doc "Every readable creative, in declaration order. Used by the renderer and tests."
  def creatives do
    creative_files()
    |> Enum.flat_map(&read_creative/1)
  end

  @doc "Whether a creative leaks an answer from `chapter`."
  def answer_free?(creative, nil), do: not blank?(creative_text(creative))

  def answer_free?(creative, chapter) do
    text = creative_text(creative) |> String.downcase()

    chapter
    |> answers()
    |> Enum.reject(&blank?/1)
    |> Enum.all?(fn answer -> not String.contains?(text, String.downcase(answer)) end)
  end

  defp recap_for(chapter_id, previous, chapter) do
    creatives()
    |> Enum.filter(fn creative ->
      creative["slot"] == @chapter_start_slot and creative["air_after"] == previous["id"]
    end)
    |> Enum.sort_by(&{order(&1), &1["id"]})
    |> Enum.find(&recap_allowed?(&1, previous, chapter))
    |> case do
      nil -> nil
      creative -> decorate(creative, chapter_id, "chapter_start:")
    end
  end

  defp candidates(chapter_id) do
    creatives()
    |> Enum.filter(fn creative ->
      creative["slot"] == @slot and creative["air_after"] == chapter_id
    end)
    |> Enum.sort_by(&{order(&1), &1["id"]})
  end

  defp recap_allowed?(creative, previous, chapter) do
    creative["kind"] == "recap" and
      creative["lesson"] == previous["lesson"] and
      answer_free?(creative, chapter)
  end

  defp previous_chapter(id) do
    chapters = Story.chapters()

    case Enum.find_index(chapters, &(&1["id"] == id)) do
      index when is_integer(index) and index > 0 -> Enum.at(chapters, index - 1)
      _ -> nil
    end
  end

  defp allowed?(creative, chapter_id) do
    next = Story.next_chapter(chapter_id)

    case creative["kind"] do
      "trailer" -> trailer_allowed?(creative, next)
      "sponsor" -> sponsor_allowed?(creative, chapter_id, next)
      kind when kind in ["correction", "psa"] -> answer_free?(creative, next)
      _ -> false
    end
  end

  defp trailer_allowed?(_creative, nil), do: false

  defp trailer_allowed?(creative, next) do
    creative["lesson"] == next["lesson"] and answer_free?(creative, next)
  end

  defp sponsor_allowed?(creative, chapter_id, next) do
    old_enough? =
      case {chapter_index(chapter_id), chapter_index(lesson_chapter(creative))} do
        {air, lesson} when is_integer(air) and is_integer(lesson) ->
          air - lesson >= @sponsor_min_age

        _ ->
          false
      end

    old_enough? and answer_free?(creative, next)
  end

  defp lesson_chapter(creative) do
    (Story.season()["chapters"] || [])
    |> Enum.find_value(fn
      %{"lesson" => lesson, "id" => id} ->
        if lesson == creative["lesson"], do: id

      _ ->
        nil
    end)
  end

  defp chapter_index(id) do
    Enum.find_index(Story.chapters(), &(&1["id"] == id))
  end

  defp answers(chapter) do
    chapter
    |> Map.get("scenes", %{})
    |> Map.values()
    |> Enum.flat_map(fn scene ->
      choice = scene["choice"] || %{}

      correct =
        choice
        |> Map.get("options", [])
        |> Enum.filter(& &1["correct"])
        |> Enum.map(& &1["label"])

      correct ++ [get_in(choice, ["card", "back"])]
    end)
  end

  defp creative_text(creative) do
    [
      creative["title"],
      creative["body"],
      get_in(creative, ["tagline", "prompt"])
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  defp decorate(creative, chapter_id, prefix) do
    %{
      "id" => creative["id"],
      "kind" => creative["kind"],
      "boundary_key" => prefix <> chapter_id,
      "title" => creative["title"],
      "body" => creative["body"],
      "tagline" => creative["tagline"],
      "media" => creative["media"],
      "sponsor" => creative["sponsor"],
      "lesson" => creative["lesson"]
    }
  end

  defp order(creative), do: creative["order"] || 0

  defp creative_files do
    dirs =
      [builtin_creatives_dir(), Application.get_env(:bot_army_terrain, :ads_dir)]
      |> Enum.reject(&is_nil/1)

    dirs
    |> Enum.uniq()
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "*.json")))
    |> Enum.sort()
  end

  # The compile-time path is the source checkout. A release carries the same files under
  # `:code.priv_dir/1`, and that is the one the running bot can read.
  defp builtin_creatives_dir do
    case :code.priv_dir(:bot_army_terrain) do
      path when is_list(path) -> Path.join([List.to_string(path), "ads", "creatives"])
      _ -> @creatives_dir
    end
  end

  defp read_creative(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, %{"id" => id, "title" => title, "body" => body} = creative}
         when is_binary(id) and is_binary(title) and is_binary(body) <-
           Jason.decode(raw) do
      [creative]
    else
      _ ->
        Logger.warning("Terrain: ignoring unreadable ad creative #{path}")
        []
    end
  end

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""
end
