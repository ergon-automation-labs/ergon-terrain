defmodule BotArmyTerrain.PulsePublisherTest do
  use ExUnit.Case, async: true

  @moduletag :core

  alias BotArmyLibraryCore.NATS.Decoder
  alias BotArmyTerrain.PulsePublisher

  describe "gossip_envelope/1" do
    test "satisfies the shared decoder so the tavern feed is not dropped" do
      envelope = PulsePublisher.gossip_envelope("🎯 Three learners active.")

      assert {:ok, decoded} = Decoder.decode(Jason.encode!(envelope))

      assert decoded["event"] == "gossip.tavern.narrated"
      assert decoded["source"] == "terrain_bot"
      assert is_binary(decoded["source_node"]) and decoded["source_node"] != ""
      assert decoded["triggered_by"] == "scheduler"
      assert decoded["payload"]["text"] == "🎯 Three learners active."
    end
  end
end
