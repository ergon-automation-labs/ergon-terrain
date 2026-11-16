defmodule BotArmyTerrain.NATS.RequestHandlerPitchTest do
  use ExUnit.Case
  @moduletag :nats

  import Mox

  alias BotArmyTerrain.NATS.RequestHandler

  setup :verify_on_exit!

  defp ask(topic, payload) do
    RequestHandler.handle_info(
      {:msg, %{topic: topic, body: Jason.encode!(payload), reply_to: "_INBOX.terrain.test"}},
      %{}
    )
  end

  defp project do
    %{
      "id" => "p1",
      "name" => "The kitchen",
      "why" => "I want to cook again.",
      "next_action" => "Clear one counter.",
      "area" => "Home"
    }
  end

  test "today answers with one spot from the projects the panel holds" do
    expect(BotArmyTerrain.PitchStoreMock, :all, fn "house" -> [] end)

    assert {:noreply, _} =
             ask("terrain.pitch.today", %{"tenant_id" => "house", "projects" => [project()]})
  end

  test "today refuses a body that is not a list of projects" do
    expect(BotArmyTerrain.PitchStoreMock, :all, 0, fn _ -> [] end)

    assert {:noreply, _} =
             ask("terrain.pitch.today", %{"tenant_id" => "house", "projects" => "nope"})
  end

  test "her why is saved and the spot becomes ready" do
    expect(BotArmyTerrain.PitchStoreMock, :get, fn "house", "p1" -> nil end)

    expect(BotArmyTerrain.PitchStoreMock, :put, fn "house", "p1", attrs ->
      assert attrs.why == "Because I want to feed people again."
      assert attrs.status == "ready"
      assert attrs.last_shown_on == nil
      {:ok, attrs}
    end)

    assert {:noreply, _} =
             ask("terrain.pitch.record", %{
               "tenant_id" => "house",
               "project_id" => "p1",
               "event" => "why",
               "why" => "  Because I want to feed people again.  "
             })
  end

  test "a blank why is refused without writing" do
    expect(BotArmyTerrain.PitchStoreMock, :get, fn "house", "p1" -> nil end)
    expect(BotArmyTerrain.PitchStoreMock, :put, 0, fn _, _, _ -> {:ok, %{}} end)

    assert {:noreply, _} =
             ask("terrain.pitch.record", %{
               "tenant_id" => "house",
               "project_id" => "p1",
               "event" => "why",
               "why" => "   "
             })
  end

  test "shown counts the airing and marks the day" do
    expect(BotArmyTerrain.PitchStoreMock, :get, fn "house", "p1" ->
      %{shown_count: 2}
    end)

    expect(BotArmyTerrain.PitchStoreMock, :put, fn "house", "p1", attrs ->
      assert attrs.shown_count == 3
      assert attrs.last_shown_on == Date.utc_today()
      {:ok, attrs}
    end)

    assert {:noreply, _} =
             ask("terrain.pitch.record", %{
               "tenant_id" => "house",
               "project_id" => "p1",
               "event" => "shown"
             })
  end

  test "start counts the five-minute door, not the impression" do
    expect(BotArmyTerrain.PitchStoreMock, :get, fn "house", "p1" -> %{start_count: 1} end)

    expect(BotArmyTerrain.PitchStoreMock, :put, fn "house", "p1", attrs ->
      assert attrs.start_count == 2
      assert %DateTime{} = attrs.last_started_at
      {:ok, attrs}
    end)

    assert {:noreply, _} =
             ask("terrain.pitch.record", %{
               "tenant_id" => "house",
               "project_id" => "p1",
               "event" => "start"
             })
  end

  test "snooze writes a date, not a judgement" do
    expect(BotArmyTerrain.PitchStoreMock, :get, fn "house", "p1" -> nil end)

    expect(BotArmyTerrain.PitchStoreMock, :put, fn "house", "p1", attrs ->
      assert %DateTime{} = attrs.snoozed_until
      {:ok, attrs}
    end)

    assert {:noreply, _} =
             ask("terrain.pitch.record", %{
               "tenant_id" => "house",
               "project_id" => "p1",
               "event" => "snooze"
             })
  end

  test "retire ends the why, not the project" do
    expect(BotArmyTerrain.PitchStoreMock, :get, fn "house", "p1" -> nil end)

    expect(BotArmyTerrain.PitchStoreMock, :put, fn "house", "p1", attrs ->
      assert attrs.status == "retired"
      assert %DateTime{} = attrs.retired_at
      {:ok, attrs}
    end)

    assert {:noreply, _} =
             ask("terrain.pitch.record", %{
               "tenant_id" => "house",
               "project_id" => "p1",
               "event" => "retire"
             })
  end

  test "an unknown event is refused without writing" do
    expect(BotArmyTerrain.PitchStoreMock, :get, fn "house", "p1" -> nil end)
    expect(BotArmyTerrain.PitchStoreMock, :put, 0, fn _, _, _ -> {:ok, %{}} end)

    assert {:noreply, _} =
             ask("terrain.pitch.record", %{
               "tenant_id" => "house",
               "project_id" => "p1",
               "event" => "launch"
             })
  end

  test "a record with no project is refused before any read" do
    expect(BotArmyTerrain.PitchStoreMock, :get, 0, fn _, _ -> nil end)
    expect(BotArmyTerrain.PitchStoreMock, :put, 0, fn _, _, _ -> {:ok, %{}} end)

    assert {:noreply, _} =
             ask("terrain.pitch.record", %{"tenant_id" => "house", "event" => "shown"})
  end
end
