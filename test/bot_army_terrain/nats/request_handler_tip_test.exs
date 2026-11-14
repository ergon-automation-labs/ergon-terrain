defmodule BotArmyTerrain.NATS.RequestHandlerTipTest do
  use ExUnit.Case
  @moduletag :nats

  import Mox

  alias BotArmyTerrain.NATS.RequestHandler

  setup :verify_on_exit!

  @tenant BotArmyLibraryCore.Tenant.default_tenant_id()

  defp ask(payload) do
    RequestHandler.handle_info(
      {:msg,
       %{
         topic: "terrain.tip.today",
         body: Jason.encode!(payload),
         reply_to: "_INBOX.terrain.test"
       }},
      %{}
    )
  end

  test "reads every active deck's cards, tenant first" do
    expect(BotArmyTerrain.TrackStoreMock, :list_tracks, fn opts ->
      assert opts[:status] == "active"
      [%{id: "t1", name: "Greek"}, %{id: "t2", name: "Kubernetes"}]
    end)

    expect(BotArmyTerrain.CardStoreMock, :list_cards_for_track, 2, fn tenant, track ->
      assert tenant == @tenant
      assert track in ["t1", "t2"]

      [
        %{
          id: "c-" <> track,
          front: "What is α?",
          back: "alpha",
          hook: "**A**lpha is an *arrow*.",
          state: "new",
          next_review_at: ~U[2026-11-01 00:00:00Z],
          last_reviewed_at: nil
        }
      ]
    end)

    assert {:noreply, _} = ask(%{"date" => "2026-11-14", "since" => "2026-11-14T07:00:00Z"})
  end

  test "a malformed date asks the stores nothing" do
    expect(BotArmyTerrain.TrackStoreMock, :list_tracks, 0, fn _ -> [] end)
    assert {:noreply, _} = ask(%{"date" => "Friday"})
  end
end
