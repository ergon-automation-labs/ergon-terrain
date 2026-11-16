defmodule BotArmyTerrain.Ads do
  @moduledoc """
  The story's interstitials, chosen at a chapter boundary.

  A creative is a text ad first: a title, two short paragraphs that *show* why a lesson is
  useful, and one question with a blank where she supplies the connection. A `media` key may
  name a motion-comic enhancement, but the text is canonical and the page never depends on the
  video.

  Interstitials are not an ad network. There are two slots — the end of a chapter
  (`story_boundary`) and the first scene of the next (`chapter_start`, used for the recap) — one
  creative per boundary, no countdown, no urgency, and `ads_enabled: false` is absolute for
  commercials. A recap is story, not inventory, so it still opens the chapter when ads are off.
  A trailer for the next chapter is refused if it would leak any of that chapter's answers; a
  sponsor is refused until its lesson is at least two chapters old.
  """

  require Logger

  alias BotArmyTerrain.Story

  @creatives_dir Path.expand("../../priv/ads/creatives", __DIR__)
  @slot "story_boundary"
  @chapter_start_slot "chapter_start"
  @sponsor_min_age 2
  @silence_days 7
  @max_per_day 2
  @max_per_lesson 3
  @required_fields ~w(id kind slot air_after title body lesson)
  @kinds ~w(trailer sponsor recap correction psa)
  @runtime_ads_default "/var/lib/bot_army/terrain_bot/ads"

  @doc """
  Whether the catalogue has already spent its budget for `creative` on `date`.

  `events` are impression rows from the last week (`AdEventStore.impressions_since/2`). Two
  impressions in the household day is a full day; three about one lesson in the window is a
  full lesson. A boundary she has already seen is handled separately by `seen?/2`, because a
  refresh is not a second airing.
  """
  def capped?(events, date, creative) when is_list(events) and is_map(creative) do
    daily_count(events, date) >= @max_per_day or
      lesson_count(events, creative["lesson"]) >= @max_per_lesson
  end

  def capped?(_events, _date, _creative), do: false

  @doc "Every creative that teaches `lesson`, by id. Used to count a lesson's airings."
  def lesson_creative_ids(lesson) when is_binary(lesson) do
    creatives()
    |> Enum.filter(&(&1["lesson"] == lesson))
    |> Enum.map(& &1["id"])
  end

  def lesson_creative_ids(_lesson), do: []

  @doc "Whether interstitials are allowed at all. `false` is absolute for commercials."
  def enabled? do
    Application.get_env(:bot_army_terrain, :ads_enabled, true) != false
  end

  @doc """
  The one creative that may air at the end of `progress.chapter`, or nil.

  The read is local: a handful of JSON files, the already-cached chapter list, and string
  checks. No model, no render, no network.
  """
  def for_chapter(progress, _date, opts \\ []) do
    if enabled?() and not silent?(opts) do
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
  first scene, so a reload mid-chapter cannot bring it back. It survives `ads_enabled: false`
  and the skip-silence rule: turning off commercials is not the same as turning off the story.
  """
  def for_scene(progress, _date, _opts \\ []) do
    chapter_recap(progress)
  end

  defp silent?(opts), do: Keyword.get(opts, :silent, false)

  defp chapter_recap(progress) do
    chapter = Story.chapter(progress.chapter)
    previous = previous_chapter(progress.chapter)

    if chapter && previous && progress.scene_id == chapter["start"] do
      recap_for(progress.chapter, previous, chapter)
    end
  end

  @doc """
  Whether two skipped interstitials in a row put the story's ads to sleep for a week.

  The silence is measured from the second skip: a skip is a "not this" and two in a row is a
  clear enough answer that continuing to ask would be nagging. After seven days the catalogue
  is offered again. The list is newest first.
  """
  def silenced?([latest | [_previous | _]], %Date{} = date) do
    case Map.get(latest, :occurred_on) || Map.get(latest, "occurred_on") do
      %Date{} = skipped -> Date.diff(date, skipped) < @silence_days
      _ -> false
    end
  end

  def silenced?(_events, _date), do: false

  @doc "The event kinds a story interstitial may record."
  def event_kinds, do: ~w(impression skip answer start)

  @doc """
  Check every creative against the canon and the placement rules.

  This is what `mix terrain.ads.lint` runs before a creative is allowed near her. It refuses a
  trailer with no next chapter or the wrong lesson, a recap that does not restate the chapter
  she just finished, a sponsor that is too young, any body or tagline that leaks an answer, and
  a file missing the fields the panel renders.
  """
  def lint(creatives \\ creatives()) do
    errors =
      Enum.flat_map(creatives, &validate_creative/1) ++ duplicate_errors(creatives)

    case errors do
      [] -> {:ok, length(creatives)}
      _ -> {:error, errors}
    end
  end

  @doc "Every readable creative, in declaration order. Used by the renderer and tests."
  def creatives do
    creative_files()
    |> Enum.flat_map(&read_creative/1)
  end

  @doc """
  Which kinds of interstitial already exist for the boundary after `chapter_id`.

  The producer uses this to stay out of the way of authored canon: if a chapter boundary
  already has a recap and a trailer, there is nothing to write.
  """
  def coverage(chapter_id) do
    creatives = creatives()

    %{
      "recap" =>
        Enum.any?(creatives, fn creative ->
          creative["kind"] == "recap" and creative["slot"] == @chapter_start_slot and
            creative["air_after"] == chapter_id
        end),
      "trailer" =>
        Enum.any?(creatives, fn creative ->
          creative["kind"] == "trailer" and creative["slot"] == @slot and
            creative["air_after"] == chapter_id
        end)
    }
  end

  @doc "The directory a producer writes new creatives into."
  def ads_dir do
    Application.get_env(:bot_army_terrain, :ads_dir, @runtime_ads_default)
  end

  @doc """
  Write one creative into the runtime catalogue, atomically.

  The file is the durable artifact; a crash between rename and reply leaves a complete creative
  or none at all.
  """
  def publish_creative(%{"id" => id} = creative) when is_binary(id) do
    dir = ads_dir()
    path = Path.join(dir, file_name(id))
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp, Jason.encode!(creative, pretty: true) <> "\n"),
         :ok <- File.rename(tmp, path) do
      {:ok, path}
    end
  end

  def publish_creative(_creative), do: {:error, :missing_id}

  defp file_name(id), do: Regex.replace(~r/[^A-Za-z0-9_-]/, id, "_") <> ".json"

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
      [builtin_creatives_dir(), ads_dir()]
      |> Enum.reject(&is_nil/1)

    dirs
    |> Enum.uniq()
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "*.json")))
    |> Enum.sort()
  end

  defp validate_creative(creative) do
    id = creative["id"] || "(no id)"

    missing =
      for field <- @required_fields, not present?(creative[field]), do: "#{id}: missing #{field}"

    missing ++
      kind_errors(creative["kind"], creative, id) ++
      tagline_errors(creative["tagline"], id) ++ media_errors(creative["media"], id)
  end

  defp kind_errors(kind, creative, id) when kind in @kinds do
    slot_errors(kind, creative, id) ++ content_errors(kind, creative, id)
  end

  defp kind_errors(kind, _creative, id), do: ["#{id}: unknown kind #{inspect(kind)}"]

  defp slot_errors(kind, creative, id) do
    expected = if kind == "recap", do: @chapter_start_slot, else: @slot

    if creative["slot"] == expected do
      []
    else
      ["#{id}: slot must be #{expected} for a #{kind}"]
    end
  end

  defp content_errors(kind, creative, id) do
    chapter_id = creative["air_after"]

    cond do
      Story.chapter(chapter_id) ->
        kind_content_errors(kind, creative, id)

      Story.season_chapter(chapter_id) ->
        # Authored ahead of the chapter it follows. There is no canon to check it against
        # yet, so it is not an error; `for_chapter` will not serve it before the boundary.
        []

      true ->
        ["#{id}: air_after #{inspect(chapter_id)} is not in the season"]
    end
  end

  defp kind_content_errors("trailer", creative, id), do: trailer_errors(creative, id)
  defp kind_content_errors("recap", creative, id), do: recap_errors(creative, id)
  defp kind_content_errors("sponsor", creative, id), do: sponsor_errors(creative, id)

  defp kind_content_errors(_kind, creative, id),
    do: answer_errors(creative, id, next_chapter(creative))

  defp trailer_errors(creative, id) do
    case next_chapter(creative) do
      nil ->
        ["#{id}: a trailer needs a next chapter"]

      next ->
        lesson_errors(creative, next["lesson"], id) ++ answer_errors(creative, id, next)
    end
  end

  defp recap_errors(creative, id) do
    previous = Story.chapter(creative["air_after"])
    current = next_chapter(creative)

    cond do
      is_nil(current) ->
        ["#{id}: a recap needs a next chapter to open"]

      creative["lesson"] != previous["lesson"] ->
        ["#{id}: the recap must restate the previous lesson"]

      true ->
        answer_errors(creative, id, current)
    end
  end

  defp sponsor_errors(creative, id) do
    next = next_chapter(creative)

    if sponsor_allowed?(creative, creative["air_after"], next) do
      []
    else
      ["#{id}: the sponsoring lesson is too young, or the body leaks the next chapter"]
    end
  end

  defp lesson_errors(creative, lesson, id) do
    if creative["lesson"] == lesson do
      []
    else
      ["#{id}: lesson must match the next chapter exactly"]
    end
  end

  defp answer_errors(creative, id, chapter) do
    if answer_free?(creative, chapter) do
      []
    else
      ["#{id}: the body or tagline leaks an answer from the next chapter"]
    end
  end

  defp next_chapter(creative), do: Story.next_chapter(creative["air_after"])

  defp tagline_errors(nil, _id), do: []

  defp tagline_errors(%{} = tagline, id) do
    prompt = tagline["prompt"]
    max = tagline["max_chars"]

    cond do
      not present?(prompt) -> ["#{id}: tagline.prompt is required"]
      not is_integer(max) or max <= 0 -> ["#{id}: tagline.max_chars must be a positive integer"]
      true -> []
    end
  end

  defp tagline_errors(_tagline, id), do: ["#{id}: tagline must be an object"]

  defp media_errors(nil, _id), do: []

  defp media_errors(%{} = media, id) do
    if present?(media["key"]), do: [], else: ["#{id}: media.key is required"]
  end

  defp media_errors(_media, id), do: ["#{id}: media must be an object"]

  defp duplicate_errors(creatives) do
    creatives
    |> Enum.frequencies_by(& &1["id"])
    |> Enum.filter(fn {id, count} -> present?(id) and count > 1 end)
    |> Enum.map(fn {id, count} -> "#{id}: appears #{count} times" end)
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp daily_count(events, date) do
    Enum.count(events, &same_day?(field(&1, :occurred_on), date))
  end

  defp lesson_count(events, lesson) do
    ids = MapSet.new(lesson_creative_ids(lesson))

    Enum.count(events, fn event ->
      MapSet.member?(ids, field(event, :creative_id))
    end)
  end

  defp same_day?(value, date), do: value == date or value == Date.to_iso8601(date)

  defp field(event, key) when is_map(event) do
    Map.get(event, key) || Map.get(event, Atom.to_string(key))
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
