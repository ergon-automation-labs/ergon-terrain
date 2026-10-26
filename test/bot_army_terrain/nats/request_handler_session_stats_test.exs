defmodule BotArmyTerrain.NATS.RequestHandlerSessionStatsTest do
  @moduledoc """
  `terrain.session.stats` — the read the maid's card makes to say "this sitting: 3 cards".

  The clause called `store.get_session_stats(session_id)`. The store's function takes the
  tenant *and* the session (`get_session_stats/2`), so the call raised `UndefinedFunctionError`
  inside `handle_request/2`, which killed the RequestHandler — every registered read on the
  bot, not just this one. On the wire that is indistinguishable from a slow bot: a
  request/reply with a dead handler times out and says nothing.

  Measured on mini 2026-10-26 14:34: `** (UndefinedFunctionError) function
  BotArmyTerrain.ReviewSessionStore.get_session_stats/1 is undefined or private`, three times,
  one per ask.

  The assertion is on what the store was asked, which is where the defect was.
  """
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

  test "asks the store for the session in this tenant" do
    tenant_id = BotArmyLibraryCore.Tenant.default_tenant_id()

    expect(BotArmyTerrain.ReviewSessionStoreMock, :get_session_stats, fn asked_tenant,
                                                                         asked_session ->
      assert asked_tenant == tenant_id
      assert asked_session == "s-1"

      {:ok, %{cards_reviewed: 3, cards_correct: 2, state: "active"}}
    end)

    assert {:noreply, _state} =
             ask("terrain.session.stats", %{"session_id" => "s-1", "tenant_id" => tenant_id})
  end

  test "a payload with no session answers instead of asking the store" do
    expect(BotArmyTerrain.ReviewSessionStoreMock, :get_session_stats, 0, fn _, _ ->
      {:ok, %{}}
    end)

    assert {:noreply, _state} = ask("terrain.session.stats", %{})
  end

  test "a read that raises is refused, and the handler survives" do
    tenant_id = BotArmyLibraryCore.Tenant.default_tenant_id()

    expect(BotArmyTerrain.ReviewSessionStoreMock, :get_session_stats, fn _, _ ->
      raise "the store fell over"
    end)

    assert {:noreply, _state} =
             ask("terrain.session.stats", %{"session_id" => "s-1", "tenant_id" => tenant_id})

    # The process is still here to be asked the next question. Before `answer/2` this
    # assert was the whole defect: the handler had terminated by now.
    expect(BotArmyTerrain.ReviewSessionStoreMock, :get_session_stats, fn _, _ ->
      {:ok, %{cards_reviewed: 1, cards_correct: 1, state: "active"}}
    end)

    assert {:noreply, _state} =
             ask("terrain.session.stats", %{"session_id" => "s-2", "tenant_id" => tenant_id})
  end
end
