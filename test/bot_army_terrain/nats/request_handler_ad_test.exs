defmodule BotArmyTerrain.NATS.RequestHandlerAdTest do
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

  defp event(overrides \\ %{}) do
    Map.merge(
      %{
        "tenant_id" => "house",
        "creative_id" => "ch1-trailer-ch2",
        "kind" => "impression",
        "boundary_key" => "chapter_end:ch1",
        "date" => "2026-11-16"
      },
      overrides
    )
  end

  test "an impression is filed against the boundary and the household day" do
    parent = self()

    expect(BotArmyTerrain.AdEventStoreMock, :record, fn "house", attrs ->
      send(parent, {:recorded, attrs})
      {:ok, Map.put(attrs, :id, "event-1")}
    end)

    assert {:noreply, _} = ask("terrain.ad.event", event())

    assert_received {:recorded, attrs}
    assert attrs.creative_id == "ch1-trailer-ch2"
    assert attrs.kind == "impression"
    assert attrs.boundary_key == "chapter_end:ch1"
    assert attrs.occurred_on == ~D[2026-11-16]
  end

  test "a skip is recorded like any other event" do
    expect(BotArmyTerrain.AdEventStoreMock, :record, fn "house", attrs ->
      assert attrs.kind == "skip"
      {:ok, attrs}
    end)

    assert {:noreply, _} = ask("terrain.ad.event", event(%{"kind" => "skip"}))
  end

  test "an unknown event is refused without writing" do
    expect(BotArmyTerrain.AdEventStoreMock, :record, 0, fn _, _ -> {:ok, %{}} end)

    assert {:noreply, _} = ask("terrain.ad.event", event(%{"kind" => "click"}))
  end

  test "an event without a boundary is refused without writing" do
    expect(BotArmyTerrain.AdEventStoreMock, :record, 0, fn _, _ -> {:ok, %{}} end)

    assert {:noreply, _} = ask("terrain.ad.event", event(%{"boundary_key" => ""}))
  end
end
