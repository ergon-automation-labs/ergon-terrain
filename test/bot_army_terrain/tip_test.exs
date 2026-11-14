defmodule BotArmyTerrain.TipTest do
  use ExUnit.Case, async: true
  @moduletag :core

  alias BotArmyTerrain.Tip

  @date ~D[2026-11-14]
  @since ~U[2026-11-14 07:00:00Z]
  @now ~U[2026-11-14 14:00:00Z]

  defp track(name), do: %{id: "t-" <> name, name: name}

  defp card(id, opts \\ []) do
    %{
      id: id,
      state: Keyword.get(opts, :state, "review"),
      next_review_at: Keyword.get(opts, :next, ~U[2026-12-01 00:00:00Z]),
      last_reviewed_at: Keyword.get(opts, :last)
    }
  end

  test "no deck with a card is no tip" do
    assert Tip.choose([], @date, @since, @now) == nil
    assert Tip.choose([{track("Greek"), []}], @date, @since, @now) == nil
  end

  test "the deck rotates by day and skips empty decks" do
    decks = [{track("A"), [card("a")]}, {track("Empty"), []}, {track("B"), [card("b")]}]

    picks =
      for offset <- 0..3 do
        Tip.choose(decks, Date.add(@date, offset), @since, @now).track.name
      end

    assert Enum.uniq(picks) |> Enum.sort() == ["A", "B"]
    assert Enum.at(picks, 0) != Enum.at(picks, 1)
  end

  test "a card answered today stays the tip" do
    decks = [
      {track("A"),
       [
         card("due", next: ~U[2026-11-01 00:00:00Z]),
         card("done", last: ~U[2026-11-14 08:00:00Z])
       ]}
    ]

    assert %{card: %{id: "done"}, answered: true} = Tip.choose(decks, @date, @since, @now)
  end

  test "otherwise the most overdue card, never a suspended one" do
    decks = [
      {track("A"),
       [
         card("later", next: ~U[2026-11-10 00:00:00Z]),
         card("oldest", next: ~U[2026-11-01 00:00:00Z]),
         card("frozen", next: ~U[2026-10-01 00:00:00Z], state: "suspended")
       ]}
    ]

    assert %{card: %{id: "oldest"}, answered: false} = Tip.choose(decks, @date, @since, @now)
  end

  test "nothing due still gives a card, the same one all day" do
    decks = [{track("A"), [card("x"), card("y"), card("z")]}]
    first = Tip.choose(decks, @date, @since, @now)
    assert first == Tip.choose(decks, @date, @since, ~U[2026-11-14 23:00:00Z])
    assert first.card.id in ["x", "y", "z"]
  end

  test "the voice is stable for a day and names every press" do
    voice = Tip.voice(@date)
    assert voice == Tip.voice(@date)
    assert Enum.all?(~w(announce flip knew not_yet later), &is_binary(voice[&1]))
  end
end
