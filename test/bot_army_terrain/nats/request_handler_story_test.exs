defmodule BotArmyTerrain.NATS.RequestHandlerStoryTest do
  use ExUnit.Case
  @moduletag :nats

  import Mox

  alias BotArmyTerrain.NATS.RequestHandler
  alias BotArmyTerrain.Story

  setup :verify_on_exit!

  setup do
    me = self()

    Application.put_env(:bot_army_terrain, :story_reviewer, fn msg ->
      send(me, {:graded, msg}) && :ok
    end)

    dir =
      Path.join(
        System.tmp_dir!(),
        "terrain_handler_story_test_#{System.unique_integer([:positive])}"
      )

    Application.put_env(:bot_army_terrain, :story_dir, dir)

    on_exit(fn ->
      File.rm_rf(dir)
      Application.delete_env(:bot_army_terrain, :story_dir)
      Application.delete_env(:bot_army_terrain, :story_reviewer)
      Application.delete_env(:bot_army_terrain, :story_writer)
    end)

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
             ask("terrain.story.choose", %{
               "date" => "2026-11-14",
               "scene_id" => "wake",
               "option" => right
             })

    assert_received {:graded, %{"card_id" => "c-nai", "quality" => 3}}
  end

  test "a second choice after a passed scene saves and grades nothing" do
    progress = %{
      Story.start()
      | scene_id: "hangar",
        chosen_on: ~D[2026-11-14],
        last_outcome: %{"status" => "passed"}
    }

    expect(BotArmyTerrain.StoryStoreMock, :get, fn _ -> progress end)
    expect(BotArmyTerrain.StoryStoreMock, :put, 0, fn _, _ -> {:ok, %{}} end)

    assert {:noreply, _} =
             ask("terrain.story.choose", %{
               "date" => "2026-11-14",
               "scene_id" => "hangar",
               "option" => 0
             })

    refute_received {:graded, _}
  end

  test "the end of a chapter starts the next one" do
    ended = %{Story.start() | scene_id: "end", facts: %{"airlock_alarm" => true}}

    expect(BotArmyTerrain.StoryStoreMock, :get, fn _ -> ended end)

    expect(BotArmyTerrain.StoryStoreMock, :put, fn _tenant, progress ->
      assert progress.chapter == "ch2"
      assert progress.scene_id == "door"
      {:ok, progress}
    end)

    assert {:noreply, _} = ask("terrain.story.next", %{"date" => "2026-11-14"})
  end

  test "at the end of the last published chapter, the writer is asked and the page says it is writing" do
    me = self()

    Application.put_env(:bot_army_terrain, :story_writer, fn tenant, chapter ->
      send(me, {:write_next, tenant, chapter})
      {:ok, :writing}
    end)

    ended = %{Story.start("ch2") | scene_id: "end"}

    expect(BotArmyTerrain.StoryStoreMock, :get, fn _ -> ended end)
    expect(BotArmyTerrain.StoryStoreMock, :put, 0, fn _, _ -> {:ok, %{}} end)

    assert {:noreply, _} = ask("terrain.story.today", %{"date" => "2026-11-14"})
    assert_received {:write_next, _tenant, "ch2"}
  end

  test "entering a chapter with no next one asks the writer while she reads" do
    me = self()

    Application.put_env(:bot_army_terrain, :story_writer, fn tenant, chapter ->
      send(me, {:write_next, tenant, chapter})
      {:ok, :queued}
    end)

    progress = Story.start("ch2")

    expect(BotArmyTerrain.StoryStoreMock, :get, fn _ -> progress end)
    expect(BotArmyTerrain.StoryStoreMock, :put, 0, fn _, _ -> {:ok, %{}} end)

    assert {:noreply, _} = ask("terrain.story.today", %{"date" => "2026-11-14"})
    assert_received {:write_next, _tenant, "ch2"}
  end

  test "the next page clears the outcome and saves the scene that follows" do
    greek_deck()

    progress = %{
      Story.start()
      | scene_id: "hangar",
        chosen_on: ~D[2026-11-14],
        last_outcome: %{"status" => "passed", "text" => "You did it."}
    }

    expect(BotArmyTerrain.StoryStoreMock, :get, fn _ -> progress end)

    expect(BotArmyTerrain.StoryStoreMock, :put, fn _tenant, saved ->
      assert saved.scene_id == "hangar"
      assert saved.chosen_on == nil
      assert saved.last_outcome == nil
      {:ok, saved}
    end)

    assert {:noreply, _} = ask("terrain.story.next", %{"date" => "2026-11-14"})
  end
end
