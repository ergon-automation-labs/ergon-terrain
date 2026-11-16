defmodule BotArmyTerrain.AdsTest do
  use ExUnit.Case, async: false
  @moduletag :core

  alias BotArmyTerrain.Ads
  alias BotArmyTerrain.Story

  setup do
    Application.put_env(:bot_army_terrain, :ads_enabled, true)

    on_exit(fn ->
      Application.delete_env(:bot_army_terrain, :ads_enabled)
      Application.delete_env(:bot_army_terrain, :ads_dir)
    end)

    :ok
  end

  test "a trailer airs at the boundary, names the next lesson, and does not leak its answers" do
    ad = Ads.for_chapter(%{chapter: "ch1"}, ~D[2026-11-15])

    assert ad["id"] == "ch1-trailer-ch2"
    assert ad["kind"] == "trailer"
    assert ad["boundary_key"] == "chapter_end:ch1"
    assert ad["lesson"] == Story.chapter("ch2")["lesson"]
    assert ad["media"]["key"] == "ch1-trailer-ch2"
    assert ad["tagline"]["prompt"] =~ "default"
    assert Ads.answer_free?(ad, Story.chapter("ch2"))
  end

  test "no creative is invented for a boundary that has none" do
    assert Ads.for_chapter(%{chapter: "ch2"}, ~D[2026-11-15]) == nil
  end

  test "a recap airs on the first scene of the next chapter and restates the last lesson" do
    ad = Ads.for_scene(%{chapter: "ch2", scene_id: "door"}, ~D[2026-11-15])

    assert ad["id"] == "ch1-recap-ch2"
    assert ad["kind"] == "recap"
    assert ad["boundary_key"] == "chapter_start:ch2"
    assert ad["lesson"] == Story.chapter("ch1")["lesson"]
    assert Ads.answer_free?(ad, Story.chapter("ch2"))
  end

  test "a recap does not air in the middle of a chapter or before the first one" do
    assert Ads.for_scene(%{chapter: "ch2", scene_id: "pen"}, ~D[2026-11-15]) == nil
    assert Ads.for_scene(%{chapter: "ch1", scene_id: "wake"}, ~D[2026-11-15]) == nil
  end

  test "ads_enabled: false is absolute for ads, but a recap is not an ad" do
    Application.put_env(:bot_army_terrain, :ads_enabled, false)

    assert Ads.for_chapter(%{chapter: "ch1"}, ~D[2026-11-15]) == nil
    assert Ads.for_scene(%{chapter: "ch2", scene_id: "door"}, ~D[2026-11-15])["kind"] == "recap"
  end

  test "a trailer whose body contains an answer from the next chapter is refused" do
    leaking = %{
      "id" => "leak",
      "title" => "Next",
      "body" => "One card. That is all you need.",
      "tagline" => %{"prompt" => "What is on the wall?"}
    }

    assert Ads.answer_free?(leaking, Story.chapter("ch2")) == false
  end

  test "a tagline that contains an answer is refused too" do
    leaking = %{
      "id" => "leak",
      "title" => "Next",
      "body" => "A manifest is not a suggestion.",
      "tagline" => %{"prompt" => "Which port? Only 30014."}
    }

    assert Ads.answer_free?(leaking, Story.chapter("ch2")) == false
  end

  test "a sponsor waits until its lesson is at least two chapters old" do
    # The sponsor creative targets ch1 and is declared after ch3. Ch3 is not published yet, so
    # there is no ch3 boundary and no airing; the rule is checked by the creative's own age.
    assert Enum.any?(Ads.creatives(), &(&1["id"] == "ch3-sponsor-ch1"))
    assert Ads.for_chapter(%{chapter: "ch2"}, ~D[2026-11-15]) == nil
  end

  test "two skipped interstitials in a row silence the catalogue for seven days" do
    latest = %{"occurred_on" => ~D[2026-11-16]}
    previous = %{"occurred_on" => ~D[2026-11-15]}

    assert Ads.silenced?([latest, previous], ~D[2026-11-16])
    assert Ads.silenced?([latest, previous], ~D[2026-11-22])
    refute Ads.silenced?([latest, previous], ~D[2026-11-23])

    # The store hands back atom-keyed rows; the pure rule reads both shapes.
    assert Ads.silenced?([%{occurred_on: ~D[2026-11-16]}, previous], ~D[2026-11-16])
  end

  test "one skip is not a silence" do
    refute Ads.silenced?([%{"occurred_on" => ~D[2026-11-16]}], ~D[2026-11-16])
    refute Ads.silenced?([], ~D[2026-11-16])
  end

  test "a silenced catalogue serves no trailer, but the recap still opens the chapter" do
    progress = %{chapter: "ch1", scene_id: "edit"}
    recap = %{chapter: "ch2", scene_id: "door"}

    assert Ads.for_chapter(progress, ~D[2026-11-16])["kind"] == "trailer"
    assert is_nil(Ads.for_chapter(progress, ~D[2026-11-16], silent: true))
    assert Ads.for_scene(recap, ~D[2026-11-16], silent: true)["kind"] == "recap"
  end
end
