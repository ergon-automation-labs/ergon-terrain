defmodule BotArmyTerrain.NATS.RequestHandlerReviewSubmitTest do
  @moduledoc """
  `terrain.review.submit` answered as a request, not only as a publish.

  The subject has been declared `:request_reply` since it was registered, but only the
  no-reply clause had a body for it, so a caller that waited for an ack was answered
  `unknown_topic` by the catch-all and the review was never recorded — while the identical
  payload, published without a reply address, worked. A page cannot tell those two apart
  without waiting, which is why the maid's panel waits.

  The reply is published by the handler rather than returned, so the assertion is on the
  store: reaching `ReviewHandler` at all is the difference between the old behaviour (nothing
  happened) and this one.
  """
  use ExUnit.Case
  @moduletag :nats

  import Mox

  alias BotArmyTerrain.NATS.RequestHandler

  setup :verify_on_exit!

  test "a review that carries a reply address is recorded" do
    tenant_id = BotArmyLibraryCore.Tenant.default_tenant_id()

    expect(BotArmyTerrain.CardStoreMock, :get_card, fn asked, "card-1" ->
      assert asked == tenant_id
      %{id: "card-1", ease_factor: 2.5, interval_days: 1, repetitions: 0}
    end)

    expect(BotArmyTerrain.CardStoreMock, :update_card, fn _tenant, _card, attrs ->
      assert attrs.repetitions == 1
      {:ok, %{}}
    end)

    body =
      Jason.encode!(%{
        "card_id" => "card-1",
        "quality" => 4,
        "tenant_id" => tenant_id
      })

    assert {:noreply, _state} =
             RequestHandler.handle_info(
               {:msg,
                %{topic: "terrain.review.submit", body: body, reply_to: "_INBOX.terrain.test"}},
               %{}
             )
  end

  test "a review with no card is refused rather than reaching the store" do
    expect(BotArmyTerrain.CardStoreMock, :get_card, 0, fn _, _ -> %{} end)

    body = Jason.encode!(%{"quality" => 4})

    assert {:noreply, _state} =
             RequestHandler.handle_info(
               {:msg,
                %{topic: "terrain.review.submit", body: body, reply_to: "_INBOX.terrain.test"}},
               %{}
             )
  end
end
