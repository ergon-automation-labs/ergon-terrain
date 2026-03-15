defmodule BotArmyTerrain.Handlers.ReviewHandlerTest do
  use ExUnit.Case
  import Mox

  alias BotArmyTerrain.Handlers.ReviewHandler

  setup :verify_on_exit!

  describe "handle_submit/1" do
    test "valid quality 4: updates card with SM-2 fields" do
      card = %{
        id: "card-123",
        ease_factor: 2.5,
        interval_days: 1,
        repetitions: 0
      }

      message = %{
        "card_id" => "card-123",
        "quality" => 4,
        "track_id" => "track-456",
        "session_id" => "session-789",
        "elapsed_ms" => 3000
      }

      expect(BotArmyTerrain.CardStoreMock, :get_card, fn id ->
        assert id == "card-123"
        card
      end)

      expect(BotArmyTerrain.CardStoreMock, :update_card, fn updated_card, attrs ->
        assert updated_card.id == "card-123"
        assert attrs.state == "learning"
        assert attrs.interval_days == 1
        assert attrs.repetitions == 1
        assert is_float(attrs.ease_factor)
        {:ok, updated_card}
      end)

      assert :ok = ReviewHandler.handle_submit(message)
    end

    test "quality 5 (perfect): increases interval and ease factor" do
      card = %{
        id: "card-123",
        ease_factor: 2.5,
        interval_days: 1,
        repetitions: 1
      }

      message = %{
        "card_id" => "card-123",
        "quality" => 5
      }

      expect(BotArmyTerrain.CardStoreMock, :get_card, fn _id -> card end)

      expect(BotArmyTerrain.CardStoreMock, :update_card, fn _card, attrs ->
        assert attrs.repetitions == 2
        assert attrs.interval_days == 3
        assert attrs.ease_factor > 2.5
        {:ok, card}
      end)

      assert :ok = ReviewHandler.handle_submit(message)
    end

    test "quality 0 (fail): resets card to learning" do
      card = %{
        id: "card-456",
        ease_factor: 2.5,
        interval_days: 10,
        repetitions: 5
      }

      message = %{
        "card_id" => "card-456",
        "quality" => 0
      }

      expect(BotArmyTerrain.CardStoreMock, :get_card, fn _id -> card end)

      expect(BotArmyTerrain.CardStoreMock, :update_card, fn _card, attrs ->
        assert attrs.repetitions == 0
        assert attrs.interval_days == 1
        assert attrs.state == "learning"
        assert attrs.ease_factor < 2.5
        {:ok, card}
      end)

      assert :ok = ReviewHandler.handle_submit(message)
    end

    test "quality 3 (pass): increments repetitions" do
      card = %{
        id: "card-789",
        ease_factor: 2.5,
        interval_days: 1,
        repetitions: 0
      }

      message = %{
        "card_id" => "card-789",
        "quality" => 3
      }

      expect(BotArmyTerrain.CardStoreMock, :get_card, fn _id -> card end)

      expect(BotArmyTerrain.CardStoreMock, :update_card, fn _card, attrs ->
        assert attrs.repetitions == 1
        assert attrs.state == "learning"
        {:ok, card}
      end)

      assert :ok = ReviewHandler.handle_submit(message)
    end

    test "missing card_id: returns error" do
      message = %{
        "quality" => 4
      }

      assert {:error, :missing_card_id} = ReviewHandler.handle_submit(message)
    end

    test "missing quality: returns error" do
      message = %{
        "card_id" => "card-123"
      }

      assert {:error, :missing_quality} = ReviewHandler.handle_submit(message)
    end

    test "invalid quality (6): returns error" do
      message = %{
        "card_id" => "card-123",
        "quality" => 6
      }

      assert {:error, :invalid_quality} = ReviewHandler.handle_submit(message)
    end

    test "invalid quality (-1): returns error" do
      message = %{
        "card_id" => "card-123",
        "quality" => -1
      }

      assert {:error, :invalid_quality} = ReviewHandler.handle_submit(message)
    end

    test "invalid quality (nil): returns missing_quality error" do
      message = %{
        "card_id" => "card-123",
        "quality" => nil
      }

      assert {:error, :missing_quality} = ReviewHandler.handle_submit(message)
    end

    test "invalid quality (string): returns error" do
      message = %{
        "card_id" => "card-123",
        "quality" => "four"
      }

      assert {:error, :invalid_quality} = ReviewHandler.handle_submit(message)
    end

    test "card not found: returns error without calling update_card" do
      message = %{
        "card_id" => "nonexistent",
        "quality" => 4
      }

      expect(BotArmyTerrain.CardStoreMock, :get_card, fn _id -> nil end)

      assert {:error, :card_not_found} = ReviewHandler.handle_submit(message)
    end

    test "update_card fails: returns error" do
      card = %{
        id: "card-123",
        ease_factor: 2.5,
        interval_days: 1,
        repetitions: 0
      }

      message = %{
        "card_id" => "card-123",
        "quality" => 4
      }

      expect(BotArmyTerrain.CardStoreMock, :get_card, fn _id -> card end)

      expect(BotArmyTerrain.CardStoreMock, :update_card, fn _card, _attrs ->
        {:error, :database_error}
      end)

      assert {:error, :database_error} = ReviewHandler.handle_submit(message)
    end

    test "float quality value: converts to integer" do
      card = %{
        id: "card-123",
        ease_factor: 2.5,
        interval_days: 1,
        repetitions: 0
      }

      message = %{
        "card_id" => "card-123",
        "quality" => 4.5
      }

      expect(BotArmyTerrain.CardStoreMock, :get_card, fn _id -> card end)

      expect(BotArmyTerrain.CardStoreMock, :update_card, fn _card, attrs ->
        assert attrs.repetitions == 1
        {:ok, card}
      end)

      assert :ok = ReviewHandler.handle_submit(message)
    end

    test "quality at boundaries: 0 works" do
      card = %{
        id: "card-123",
        ease_factor: 2.5,
        interval_days: 1,
        repetitions: 0
      }

      message = %{
        "card_id" => "card-123",
        "quality" => 0
      }

      expect(BotArmyTerrain.CardStoreMock, :get_card, fn _id -> card end)

      expect(BotArmyTerrain.CardStoreMock, :update_card, fn _card, _attrs ->
        {:ok, card}
      end)

      assert :ok = ReviewHandler.handle_submit(message)
    end

    test "quality at boundaries: 5 works" do
      card = %{
        id: "card-123",
        ease_factor: 2.5,
        interval_days: 1,
        repetitions: 0
      }

      message = %{
        "card_id" => "card-123",
        "quality" => 5
      }

      expect(BotArmyTerrain.CardStoreMock, :get_card, fn _id -> card end)

      expect(BotArmyTerrain.CardStoreMock, :update_card, fn _card, _attrs ->
        {:ok, card}
      end)

      assert :ok = ReviewHandler.handle_submit(message)
    end
  end
end
