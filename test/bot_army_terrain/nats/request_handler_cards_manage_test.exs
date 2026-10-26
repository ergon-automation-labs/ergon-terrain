defmodule BotArmyTerrain.NATS.RequestHandlerCardsManageTest do
  @moduledoc """
  The management door: `terrain.cards.{list,create,update,delete}` and
  `terrain.tracks.{create,update}`.

  Her question was "how do I manage collections and decks?" and the honest answer was that
  nothing could: `CardStore` had `create_card`/`update_card`/`delete_card` from the beginning
  and no subject exposed them, and a track's name was write-once. These tests drive the
  GenServer callback the broker drives and assert **what the store was asked**, which is where
  every defect in this file has been (the tenant and the track swapped in `cards.due`, a
  stats read with one argument where the store takes two). The reply goes to a throw-away
  inbox because the handler publishes it rather than returning it.
  """
  use ExUnit.Case
  @moduletag :nats

  import Mox

  alias BotArmyTerrain.NATS.RequestHandler

  setup :verify_on_exit!

  @tenant BotArmyLibraryCore.Tenant.default_tenant_id()
  @track "11111111-1111-1111-1111-111111111111"
  @card "22222222-2222-2222-2222-222222222222"

  defp ask(topic, payload) do
    RequestHandler.handle_info(
      {:msg, %{topic: topic, body: Jason.encode!(payload), reply_to: "_INBOX.terrain.test"}},
      %{}
    )
  end

  describe "terrain.cards.list" do
    test "asks for every card in the deck, tenant first" do
      expect(BotArmyTerrain.CardStoreMock, :list_cards_for_track, fn tenant, track ->
        assert tenant == @tenant
        assert track == @track

        [
          %{
            id: @card,
            track_id: @track,
            front: "What does a client buy?",
            back: "A result.",
            card_type: "basic",
            state: "new",
            next_review_at: ~U[2026-10-26 12:00:00.000000Z]
          }
        ]
      end)

      assert {:noreply, _state} = ask("terrain.cards.list", %{"track_id" => @track})
    end

    test "a payload naming no deck asks the store nothing" do
      expect(BotArmyTerrain.CardStoreMock, :list_cards_for_track, 0, fn _, _ -> [] end)

      assert {:noreply, _state} = ask("terrain.cards.list", %{})
    end
  end

  describe "terrain.cards.create" do
    test "adds one card to an existing deck, and counts the deck again" do
      expect(BotArmyTerrain.TrackStoreMock, :get_track, fn @track -> %{id: @track} end)

      expect(BotArmyTerrain.CardStoreMock, :create_card, fn tenant, attrs ->
        assert tenant == @tenant
        assert attrs.track_id == @track
        assert attrs.front == "Name the second question."
        assert attrs.back == "What is it worth?"
        assert attrs.card_type == "basic"

        {:ok,
         %{
           id: @card,
           track_id: @track,
           front: attrs.front,
           back: attrs.back,
           card_type: "basic",
           state: "new",
           next_review_at: nil
         }}
      end)

      expect(BotArmyTerrain.TrackStoreMock, :update_card_count_from_store, fn @tenant, @track ->
        {:ok, %{}}
      end)

      assert {:noreply, _state} =
               ask("terrain.cards.create", %{
                 "track_id" => @track,
                 "front" => "  Name the second question.  ",
                 "back" => "What is it worth?"
               })
    end

    test "a blank front is sent as nil so the changeset refuses it, not as an empty card" do
      expect(BotArmyTerrain.TrackStoreMock, :get_track, fn @track -> %{id: @track} end)

      expect(BotArmyTerrain.CardStoreMock, :create_card, fn _tenant, attrs ->
        assert attrs.front == nil
        assert attrs.back == "A result."
        {:error, :refused}
      end)

      assert {:noreply, _state} =
               ask("terrain.cards.create", %{
                 "track_id" => @track,
                 "front" => "   ",
                 "back" => "A result."
               })
    end

    test "a deck that does not exist is refused before anything is written" do
      expect(BotArmyTerrain.TrackStoreMock, :get_track, fn _id -> nil end)
      expect(BotArmyTerrain.CardStoreMock, :create_card, 0, fn _, _ -> {:ok, %{}} end)

      assert {:noreply, _state} =
               ask("terrain.cards.create", %{
                 "track_id" => "not-a-deck",
                 "front" => "q",
                 "back" => "a"
               })
    end
  end

  describe "terrain.cards.update" do
    test "edits only the field that was sent" do
      card = %{id: @card, track_id: @track, front: "old", back: "old back"}

      expect(BotArmyTerrain.CardStoreMock, :get_card, fn @tenant, @card -> card end)

      expect(BotArmyTerrain.CardStoreMock, :update_card, fn @tenant, ^card, attrs ->
        assert attrs == %{"back" => "A result, not hours."}
        {:ok, Map.put(card, :back, "A result, not hours.")}
      end)

      assert {:noreply, _state} =
               ask("terrain.cards.update", %{"card_id" => @card, "back" => "A result, not hours."})
    end

    test "a card in another house is not found, and is not written to" do
      expect(BotArmyTerrain.CardStoreMock, :get_card, fn @tenant, @card -> nil end)
      expect(BotArmyTerrain.CardStoreMock, :update_card, 0, fn _, _, _ -> {:ok, %{}} end)

      assert {:noreply, _state} =
               ask("terrain.cards.update", %{"card_id" => @card, "front" => "x"})
    end
  end

  describe "terrain.cards.delete" do
    test "reads the card tenant-scoped first, then removes it and recounts the deck" do
      card = %{id: @card, track_id: @track}

      expect(BotArmyTerrain.CardStoreMock, :get_card, fn @tenant, @card -> card end)
      expect(BotArmyTerrain.CardStoreMock, :delete_card, fn @card -> {:ok, card} end)

      expect(BotArmyTerrain.TrackStoreMock, :update_card_count_from_store, fn @tenant, @track ->
        {:ok, %{}}
      end)

      assert {:noreply, _state} = ask("terrain.cards.delete", %{"card_id" => @card})
    end

    test "a card that is not in this house is never handed to the delete call" do
      expect(BotArmyTerrain.CardStoreMock, :get_card, fn _tenant, _card -> nil end)
      expect(BotArmyTerrain.CardStoreMock, :delete_card, 0, fn _ -> {:ok, %{}} end)

      assert {:noreply, _state} = ask("terrain.cards.delete", %{"card_id" => @card})
    end
  end

  describe "terrain.tracks.create" do
    test "creates a deck the house does not have yet" do
      expect(BotArmyTerrain.TrackStoreMock, :get_by_name, fn "Negotiating" -> nil end)

      expect(BotArmyTerrain.TrackStoreMock, :create_track, fn attrs ->
        assert attrs.name == "Negotiating"
        assert attrs.tenant_id == @tenant
        assert attrs.description == "The walk-away and the number."
        {:ok, %{id: @track, name: "Negotiating", card_count: 0, chunk_count: 0, status: "active"}}
      end)

      assert {:noreply, _state} =
               ask("terrain.tracks.create", %{
                 "name" => "  Negotiating  ",
                 "description" => "The walk-away and the number."
               })
    end

    test "a name that is taken is refused rather than answered with the deck that has it" do
      expect(BotArmyTerrain.TrackStoreMock, :get_by_name, fn "Money Making" ->
        %{id: @track, name: "Money Making"}
      end)

      expect(BotArmyTerrain.TrackStoreMock, :create_track, 0, fn _ -> {:ok, %{}} end)

      assert {:noreply, _state} = ask("terrain.tracks.create", %{"name" => "Money Making"})
    end

    test "a deck with no name is not created" do
      expect(BotArmyTerrain.TrackStoreMock, :get_by_name, 0, fn _ -> nil end)
      expect(BotArmyTerrain.TrackStoreMock, :create_track, 0, fn _ -> {:ok, %{}} end)

      assert {:noreply, _state} = ask("terrain.tracks.create", %{"name" => "   "})
    end
  end

  describe "terrain.tracks.update" do
    test "renames a deck, as long as the new name is free" do
      track = %{id: @track, tenant_id: @tenant, name: "Money Making"}

      expect(BotArmyTerrain.TrackStoreMock, :get_track, fn @track -> track end)
      expect(BotArmyTerrain.TrackStoreMock, :get_by_name, fn "Money" -> nil end)

      expect(BotArmyTerrain.TrackStoreMock, :update_track, fn ^track, attrs ->
        assert attrs == %{"name" => "Money"}
        {:ok, %{track | name: "Money"}}
      end)

      assert {:noreply, _state} =
               ask("terrain.tracks.update", %{"track_id" => @track, "name" => "Money"})
    end

    test "renaming a deck to its own name is not a collision" do
      track = %{id: @track, tenant_id: @tenant, name: "Money Making"}

      expect(BotArmyTerrain.TrackStoreMock, :get_track, fn @track -> track end)
      expect(BotArmyTerrain.TrackStoreMock, :get_by_name, fn "Money Making" -> track end)

      expect(BotArmyTerrain.TrackStoreMock, :update_track, fn ^track, _attrs ->
        {:ok, track}
      end)

      assert {:noreply, _state} =
               ask("terrain.tracks.update", %{"track_id" => @track, "name" => "Money Making"})
    end

    test "a deck in another house is not renamed" do
      expect(BotArmyTerrain.TrackStoreMock, :get_track, fn @track ->
        %{id: @track, tenant_id: Ecto.UUID.generate(), name: "Not yours"}
      end)

      expect(BotArmyTerrain.TrackStoreMock, :update_track, 0, fn _, _ -> {:ok, %{}} end)

      assert {:noreply, _state} =
               ask("terrain.tracks.update", %{"track_id" => @track, "name" => "Mine"})
    end
  end
end
