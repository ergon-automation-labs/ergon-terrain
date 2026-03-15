defmodule BotArmyTerrain.Handlers.SessionHandlerTest do
  use ExUnit.Case
  import Mox
  alias BotArmyTerrain.Handlers.SessionHandler

  setup :verify_on_exit!

  describe "handle_start/1" do
    test "creates a session and returns session_id" do
      track_id = Ecto.UUID.generate()
      session_id = Ecto.UUID.generate()

      message = %{"track_id" => track_id}

      expect(BotArmyTerrain.ReviewSessionStoreMock, :create_session, fn attrs ->
        assert attrs.track_id == track_id
        {:ok, %{id: session_id}}
      end)

      response = SessionHandler.handle_start(message)
      {:ok, data} = Jason.decode(response)

      assert Map.has_key?(data, "session_id")
      assert data["session_id"] == session_id
    end

    test "returns error for missing track_id" do
      message = %{}

      response = SessionHandler.handle_start(message)
      {:ok, data} = Jason.decode(response)

      assert Map.has_key?(data, "error")
    end

    test "returns error for invalid track_id type" do
      message = %{"track_id" => 123}

      response = SessionHandler.handle_start(message)
      {:ok, data} = Jason.decode(response)

      assert Map.has_key?(data, "error")
    end
  end

  describe "handle_end/1" do
    test "returns error for missing session_id" do
      message = %{}

      response = SessionHandler.handle_end(message)
      {:ok, data} = Jason.decode(response)

      assert Map.has_key?(data, "error")
    end

    test "returns error for invalid session_id type" do
      message = %{"session_id" => 123}

      response = SessionHandler.handle_end(message)
      {:ok, data} = Jason.decode(response)

      assert Map.has_key?(data, "error")
    end
  end
end
