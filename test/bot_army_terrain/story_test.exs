defmodule BotArmyTerrain.StoryTest do
  use ExUnit.Case, async: true
  @moduletag :core

  alias BotArmyTerrain.Story

  @day ~D[2026-11-14]
  @tomorrow ~D[2026-11-15]

  defp greek(_deck) do
    [
      %{front: "What does **Ναι** mean?", back: "**Yes.** Pronounced \"neh\"."},
      %{front: "**α** — name and sound?", back: "Alpha"},
      %{front: "**η** — what sound?", back: "ee"},
      %{front: "How do you say **thank you**?", back: "Ευχαριστώ"}
    ]
  end

  defp right_index(scene_id),
    do: Enum.find_index(Story.scene(scene_id)["choice"]["options"], & &1["correct"])

  defp wrong_index(scene_id),
    do: Enum.find_index(Story.scene(scene_id)["choice"]["options"], &(!&1["correct"]))

  test "every scene's choice is a card, and every path leads somewhere real" do
    for {id, scene} <- Story.chapter()["scenes"], scene["choice"] do
      assert %{"deck" => _, "front" => _} = scene["choice"]["card"], id
      assert Enum.count(scene["choice"]["options"], & &1["correct"]) == 1, id
      assert Enum.all?(scene["choice"]["options"], &Story.scene(&1["next"])), id
    end
  end

  test "the page never sees which option is right" do
    {:scene, view} = Story.today(Story.start(), @day)
    refute inspect(view["choice"]) =~ "correct"
    refute inspect(view["choice"]) =~ "outcome"
  end

  test "a right choice moves on, grades 4, and the morning is spent" do
    {:ok, p, {card, 4}} = Story.choose(Story.start(), "wake", right_index("wake"), @day, &greek/1)

    assert card["deck"] == "Greek"
    assert p.scene_id == "hangar"
    assert {:done, %{"correct" => true}} = Story.today(p, @day)
    assert {:error, :already_chosen} = Story.choose(p, "hangar", 0, @day, &greek/1)
    assert {:scene, %{"title" => "The Hangar Board"}} = Story.today(p, @tomorrow)
  end

  test "a wrong choice costs a fact and opens a gate whose answer stays hidden" do
    {:ok, p, {_card, 2}} = Story.choose(Story.start(), "wake", wrong_index("wake"), @day, &greek/1)

    assert p.scene_id == "wake"
    assert p.facts["airlock_alarm"] == true
    assert {:gate, %{"gate" => gate}} = Story.today(p, @day)
    assert gate["question"] =~ "Ναι"
    assert length(gate["options"]) == 3
    refute Map.has_key?(gate, "answer")
    assert "**Yes.** Pronounced \"neh\"." in gate["options"]
  end

  test "passing the gate moves on along the right path, failing it repeats the scene" do
    {:ok, p, _} = Story.choose(Story.start(), "wake", wrong_index("wake"), @day, &greek/1)
    answer = p.last_outcome["gate"]["answer"]
    miss = Enum.find(0..2, &(&1 != answer))

    {:ok, passed, {_, 3}} = Story.answer_gate(p, answer, @day)
    assert passed.scene_id == "hangar"
    assert passed.last_outcome["text"] =~ "Recalled"

    {:ok, failed, {_, 1}} = Story.answer_gate(p, miss, @day)
    assert failed.scene_id == "wake"
    assert failed.last_outcome["text"] =~ "waits for you tomorrow"
    assert {:error, :no_gate} = Story.answer_gate(failed, answer, @day)
    assert {:scene, %{"title" => "Wake Cycle"}} = Story.today(failed, @tomorrow)
  end

  test "facts come back as echoes in later scenes" do
    {:ok, p, _} = Story.choose(Story.start(), "wake", wrong_index("wake"), @day, &greek/1)
    {:ok, p, _} = Story.answer_gate(p, p.last_outcome["gate"]["answer"], @day)

    {:scene, view} = Story.today(p, @tomorrow)
    assert Enum.any?(view["echoes"], &(&1 =~ "alarm made you famous"))
  end
end
