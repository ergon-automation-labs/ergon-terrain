defmodule BotArmyTerrain.Handlers.LlmResponseHandlerTest do
  use ExUnit.Case
  import Mox

  alias BotArmyTerrain.Handlers.LlmResponseHandler

  setup :verify_on_exit!

  describe "handle_parsed" do
    test "ignores response with wrong source" do
      message = %{
        "payload" => %{
          "metadata" => %{
            "source" => "some_other_bot"
          }
        }
      }

      assert :ignore = LlmResponseHandler.handle_parsed(message)
    end

    test "ignores response with no metadata" do
      message = %{
        "payload" => %{
          "structured_data" => %{"cards" => []}
        }
      }

      assert :ignore = LlmResponseHandler.handle_parsed(message)
    end

    test "handles valid terrain_card_generation response" do
      message = %{
        "payload" => %{
          "structured_data" => %{
            "cards" => [
              %{
                "front" => "What is Elixir?",
                "back" => "A functional language",
                "card_type" => "basic"
              }
            ]
          },
          "metadata" => %{
            "source" => "terrain_card_generation",
            "track_id" => "track-123",
            "chunk_ids" => ["chunk-456"],
            "model" => "haiku"
          }
        }
      }

      expect(BotArmyTerrain.CardStoreMock, :create_card, fn _attrs -> {:ok, %{}} end)
      expect(BotArmyTerrain.TrackStoreMock, :update_card_count_from_store, fn _track_id -> {:ok, %{}} end)

      result = LlmResponseHandler.handle_parsed(message)
      assert result == :ok
    end

    test "handles response with card_type defaults to basic if missing" do
      message = %{
        "payload" => %{
          "structured_data" => %{
            "cards" => [
              %{
                "front" => "Q1?",
                "back" => "A1"
              }
            ]
          },
          "metadata" => %{
            "source" => "terrain_card_generation",
            "track_id" => "track-123",
            "chunk_ids" => ["chunk-456"],
            "model" => "haiku"
          }
        }
      }

      expect(BotArmyTerrain.CardStoreMock, :create_card, fn attrs ->
        assert attrs[:card_type] == "basic"
        {:ok, %{}}
      end)
      expect(BotArmyTerrain.TrackStoreMock, :update_card_count_from_store, fn _track_id -> {:ok, %{}} end)

      result = LlmResponseHandler.handle_parsed(message)
      assert result == :ok
    end

    test "handles multiple cards" do
      message = %{
        "payload" => %{
          "structured_data" => %{
            "cards" => [
              %{"front" => "Q1?", "back" => "A1", "card_type" => "basic"},
              %{"front" => "Q2?", "back" => "A2", "card_type" => "cloze"},
              %{"front" => "Q3?", "back" => "A3", "card_type" => "definition"}
            ]
          },
          "metadata" => %{
            "source" => "terrain_card_generation",
            "track_id" => "track-123",
            "chunk_ids" => ["chunk-456"],
            "model" => "haiku"
          }
        }
      }

      expect(BotArmyTerrain.CardStoreMock, :create_card, 3, fn _attrs -> {:ok, %{}} end)
      expect(BotArmyTerrain.TrackStoreMock, :update_card_count_from_store, fn _track_id -> {:ok, %{}} end)

      result = LlmResponseHandler.handle_parsed(message)
      assert result == :ok
    end

    test "handles response without chunk_ids" do
      message = %{
        "payload" => %{
          "structured_data" => %{
            "cards" => [
              %{"front" => "Q1?", "back" => "A1"}
            ]
          },
          "metadata" => %{
            "source" => "terrain_card_generation",
            "track_id" => "track-123",
            "model" => "haiku"
          }
        }
      }

      expect(BotArmyTerrain.CardStoreMock, :create_card, fn _attrs -> {:ok, %{}} end)
      expect(BotArmyTerrain.TrackStoreMock, :update_card_count_from_store, fn _track_id -> {:ok, %{}} end)

      result = LlmResponseHandler.handle_parsed(message)
      assert result == :ok
    end
  end
end
