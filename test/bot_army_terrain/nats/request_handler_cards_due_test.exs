defmodule BotArmyTerrain.NATS.RequestHandlerCardsDueTest do
  @moduledoc """
  `terrain.cards.due` — the read the maid's panel makes to draw the next card.

  The clause shipped broken: it called `CardStore.list_due_cards(track_id, limit: 20)`,
  which matched the default-argument arity and put the track where the *tenant* belongs and
  `[limit: 20]` where the track belongs, so the query builder raised. Nothing called the
  subject until 2026-10-26, and no test called the clause either — both of which are why a
  subject that could never answer stayed registered for months.

  These tests drive the GenServer callback the broker drives. The assertion is on what the
  store was asked, which is where the defect was; the reply goes to a throw-away inbox
  because the handler publishes it rather than returning it. The old code fails the first
  test by raising inside the query builder.
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

  test "asks the store with the tenant and the track, never one in place of the other" do
    tenant_id = BotArmyLibraryCore.Tenant.default_tenant_id()

    expect(BotArmyTerrain.CardStoreMock, :list_due_cards, fn asked_tenant, asked_track, opts ->
      assert asked_tenant == tenant_id
      assert asked_track == "11111111-1111-1111-1111-111111111111"
      assert opts == [limit: 20]

      [
        %{id: "c-1", front: "What is the deposit rule?", back: "Half up front."},
        %{id: "c-2", front: "What makes an invoice late?", back: "No reminder."}
      ]
    end)

    assert {:noreply, _state} =
             ask("terrain.cards.due", %{
               "track_id" => "11111111-1111-1111-1111-111111111111",
               "tenant_id" => tenant_id
             })
  end

  test "a payload naming no track answers instead of asking the store anything" do
    # `expect` with zero allowed calls: a store read here would be a query for no track.
    expect(BotArmyTerrain.CardStoreMock, :list_due_cards, 0, fn _, _, _ -> [] end)

    assert {:noreply, _state} = ask("terrain.cards.due", %{})
  end
end
