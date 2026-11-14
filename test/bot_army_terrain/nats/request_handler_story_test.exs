defmodule BotArmyTerrain.NATS.RequestHandlerStoryTest do
  use ExUnit.Case
  @moduletag :nats

  import Mox

  alias BotArmyTerrain.NATS.RequestHandler
  alias BotArmyTerrain.Story

  setup :verify_on_exit!

  setup do
    me = self()
    Application.put_env(:bot_army_terrain, :story_reviewer, fn msg -> send(me, {:graded, msg}) && :ok end)
    on_exit(fn -> Application.delete_env(:bot_army_terrain, :story_reviewer) end)
    :ok
  end

  defp ask(topic, payload) do
    RequestHandler.handle_info(
      {:msg, %{topic: topic, body: Jason.encode!(payload), reply_to: "_INBOX.terrain.test"}},
      %{}
    )
  end

  defp greek_deck do
    stub(BotArmyTerrain.TrackStoreMock, :get_by_name, fn _ -> %{id: "t-greek"} end)

    stub(BotArmyTerrain.CardStoreMock, :list_cards_for_track, fn _, _ ->
      [%{id: "c-nai", front: "What does **Ναι** mean?", back: "Yes", hook: nil}]
    end)
  end

  test "today starts a story that has none, and reads it without writing" do
    greek_deck()
    expect(BotArmyTerrain.StoryStoreMock, :get, fn _tenant -> nil end)
    expect(BotArmyTerrain.StoryStoreMock, :put, 0, fn _, _ -> {:ok, %{}} end)

    assert {:noreply, _} = ask("terrain.story.today", %{"date" => "2026-11-14"})
  end

  test "a right choice saves the next scene and grades the scene's card" do
    greek_deck()
    expect(BotArmyTerrain.StoryStoreMock, :get, fn _ -> Story.start() end)

    expect(BotArmyTerrain.StoryStoreMock, :put, fn _tenant, progress ->
      assert progress.scene_id == "hangar"
      {:ok, progress}
    end)

    right = Enum.find_index(Story.scene("wake")["choice"]["options"], & &1["correct"])

    assert {:noreply, _} =
             ask("terrain.story.choose", %{"date" => "2026-11-14", "scene_id" => "wake", "option" => right})

    assert_received {:graded, %{"card_id" => "c-nai", "quality" => 4}}
  end

  test "a second choice the same morning saves and grades nothing" do
    expect(BotArmyTerrain.StoryStoreMock, :get, fn _ -> %{Story.start() | chosen_on: ~D[2026-11-14]} end)
    expect(BotArmyTerrain.StoryStoreMock, :put, 0, fn _, _ -> {:ok, %{}} end)

    assert {:noreply, _} =
             ask("terrain.story.choose", %{"date" => "2026-11-14", "scene_id" => "wake", "option" => 0})

    refute_received {:graded, _}
  end
end
