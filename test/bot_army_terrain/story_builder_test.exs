defmodule BotArmyTerrain.StoryBuilderTest do
  use ExUnit.Case, async: true
  @moduletag :core

  alias BotArmyTerrain.StoryBuilder

  @cards [
    %{
      "front" => "What is a door?",
      "back" => "**A decision** about who may see the row.",
      "deck" => "Test"
    },
    %{
      "front" => "Where does the value come from?",
      "back" => "From **her** press — never a default.",
      "deck" => "Test"
    },
    %{"front" => "Which port?", "back" => "Fail-safe: 4223.", "deck" => "Test"},
    %{
      "front" => "What is a subject?",
      "back" => "A dotted name a message is sent to.",
      "deck" => "Test"
    }
  ]

  defp plan do
    %{
      "id" => "chx",
      "title" => "Chapter X",
      "start" => "one",
      "deck" => "Test",
      "scenes" => [
        scene("one", "What is a door?"),
        scene("two", "Where does the value come from?"),
        scene("three", "Which port?"),
        scene("four", "What is a subject?")
      ],
      "end" => %{"title" => "End", "text" => "The door closes."}
    }
  end

  defp scene(id, card) do
    %{
      "id" => id,
      "title" => "Scene #{id}",
      "text" => "Something happens.",
      "card" => card,
      "prompt" => "Which answer?",
      "right" => "Right.",
      "wrong" => "Wrong.",
      "wrong_label" => "A wrong answer"
    }
  end

  test "a plan becomes a chapter with the card's answer on the right button" do
    assert {:ok, chapter} = StoryBuilder.build(plan(), @cards)
    assert chapter["id"] == "chx"
    assert Map.keys(chapter["scenes"]) |> Enum.sort() == ["end", "four", "one", "three", "two"]

    one = chapter["scenes"]["one"]
    assert %{"deck" => "Test", "front" => "What is a door?"} = one["choice"]["card"]
    assert Enum.count(one["choice"]["options"], & &1["correct"]) == 1

    right = Enum.find(one["choice"]["options"], & &1["correct"])
    assert right["label"] == "A decision about who may see the row."
    assert right["next"] == "two"

    four = chapter["scenes"]["four"]
    assert Enum.all?(four["choice"]["options"], &(&1["next"] == "end"))
  end

  test "a scene that tests a card not in the deck is refused, not guessed" do
    bad = put_in(plan(), ["scenes", Access.at(0), "card"], "A card that does not exist")

    assert {:error, [reason]} = StoryBuilder.build(bad, @cards)
    assert reason =~ "not in the deck"
  end

  test "a chapter with too few scenes is refused" do
    plan = plan()
    plan = update_in(plan["scenes"], &Enum.take(&1, 3))

    assert {:error, [reason]} = StoryBuilder.build(plan, @cards)
    assert reason =~ "at least 4 scenes"
  end

  test "a duplicate scene id is refused" do
    plan = plan()
    plan = put_in(plan, ["scenes", Access.at(1), "id"], "one")

    assert {:error, [reason]} = StoryBuilder.build(plan, @cards)
    assert reason =~ "used twice"
  end

  test "the plan's order is the chain: the last scene points at the end" do
    assert {:ok, chapter} = StoryBuilder.build(plan(), @cards)
    assert chapter["scenes"]["three"]["choice"]["options"] |> Enum.all?(&(&1["next"] == "four"))
    assert chapter["scenes"]["four"]["choice"]["options"] |> Enum.all?(&(&1["next"] == "end"))
  end

  test "the answer label is plain text, because a button is not a markdown surface" do
    assert StoryBuilder.plain("**Yes.** Use `rg -n`.") == "Yes. Use rg -n."
  end
end
