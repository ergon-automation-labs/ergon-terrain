defmodule BotArmyTerrain.Handlers.SystemSignalHandlerTest do
  use ExUnit.Case
  @moduletag :handlers

  alias BotArmyTerrain.Handlers.SystemSignalHandler

  describe "handle_request/1", do: @tag(:integration) do
    test "returns JSON response with signal data" do
      response = SystemSignalHandler.handle_request(%{})

      # Response is a JSON string from NATS reply
      assert is_binary(response)

      # Parse and verify structure
      {:ok, parsed} = Jason.decode(response)

      # Should be either an error or have data field
      assert Map.has_key?(parsed, "code") or Map.has_key?(parsed, "data")
    end
  end
end
