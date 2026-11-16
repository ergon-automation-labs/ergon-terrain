defmodule BotArmyTerrain.PitchTest do
  use ExUnit.Case
  @moduletag :core

  alias BotArmyTerrain.Pitch

  @now ~U[2026-11-15 12:00:00Z]

  defp project(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "p1",
        "name" => "The kitchen",
        "why" => "I want to cook again without it feeling like a chore.",
        "next_action" => "Clear one counter.",
        "area" => "Home"
      },
      overrides
    )
  end

  test "a project with a why becomes a spot, in her own words" do
    pitch = Pitch.pick([project()], %{}, @now)

    assert pitch["kind"] == "spot"
    assert pitch["project_id"] == "p1"
    assert pitch["why"] == "I want to cook again without it feeling like a chore."
    assert pitch["next_action"] == "Clear one counter."
    assert pitch["line"] =~ "Clear one counter."
  end

  test "a project with no why is asked for one instead of skipped" do
    pitch = Pitch.pick([project(%{"why" => nil})], %{}, @now)

    assert pitch["kind"] == "ask_why"
    assert pitch["question"] == "Why does The kitchen matter to you?"
    assert pitch["next_action"] == "Clear one counter."
  end

  test "a ready spot wins over an ask" do
    ask = project(%{"id" => "p-ask", "name" => "Taxes", "why" => nil})
    spot = project(%{"id" => "p-spot"})

    assert Pitch.pick([ask, spot], %{}, @now)["project_id"] == "p-spot"
  end

  test "a snoozed project is not drawn" do
    states = %{"p1" => %{snoozed_until: DateTime.add(@now, 86_400, :second)}}
    assert Pitch.pick([project()], states, @now) == nil
  end

  test "a snooze that has ended is drawable again" do
    states = %{"p1" => %{snoozed_until: DateTime.add(@now, -86_400, :second)}}
    assert Pitch.pick([project()], states, @now)["kind"] == "spot"
  end

  test "the same project does not air twice in one day" do
    states = %{"p1" => %{last_shown_on: ~D[2026-11-15]}}
    assert Pitch.pick([project()], states, @now) == nil
  end

  test "a project shown this week waits, and one shown longer ago does not" do
    recent = %{"p1" => %{last_shown_at: DateTime.add(@now, -3 * 86_400, :second)}}
    old = %{"p1" => %{last_shown_at: DateTime.add(@now, -8 * 86_400, :second)}}

    assert Pitch.pick([project()], recent, @now) == nil
    assert Pitch.pick([project()], old, @now)["kind"] == "spot"
  end

  test "a retired why is not drawn" do
    states = %{"p1" => %{status: "retired"}}
    assert Pitch.pick([project()], states, @now) == nil
  end

  test "completed and archived projects are not drawn" do
    assert Pitch.pick([project(%{"status" => "completed"})], %{}, @now) == nil
    assert Pitch.pick([project(%{"status" => "archived"})], %{}, @now) == nil
  end

  test "a project with no doable next action has no door, so it is not drawn" do
    assert Pitch.pick([project(%{"next_action" => "  "})], %{}, @now) == nil
  end

  test "the why she wrote on the card overrides a terse project description" do
    states = %{"p1" => %{why: "Because I want to feed people again."}}

    assert Pitch.pick([project(%{"why" => "Kitchen"})], states, @now)["why"] ==
             "Because I want to feed people again."
  end

  test "ties are broken by id, so a refresh draws the same card" do
    a = project(%{"id" => "a", "name" => "A"})
    b = project(%{"id" => "b", "name" => "B"})

    assert Pitch.pick([b, a], %{}, @now)["project_id"] == "a"
    assert Pitch.pick([a, b], %{}, @now)["project_id"] == "a"
  end

  test "clean_why trims, refuses blank, and bounds the sentence" do
    assert Pitch.clean_why("  because it matters  ") == {:ok, "because it matters"}
    assert Pitch.clean_why("   ") == {:error, :blank_why}
    assert Pitch.clean_why(nil) == {:error, :blank_why}
    assert Pitch.clean_why(String.duplicate("a", 281)) == {:error, :why_too_long}
  end

  test "a snooze is seven days, not a verdict" do
    assert Pitch.snooze_until(@now) == DateTime.add(@now, 7 * 86_400, :second)
  end
end
