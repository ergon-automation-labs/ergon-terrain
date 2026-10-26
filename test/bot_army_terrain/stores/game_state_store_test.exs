defmodule BotArmyTerrain.GameStateStoreTest do
  @moduledoc """
  A read that names no track asks for no track.

  `Repo.get_by/2` refuses `nil` in a comparison, so the old clause terminated the
  RequestHandler — the one process every other read on this bot goes through. The trace in
  `/var/log/bot_army/terrain_bot.err` (2026-10-26) is the reason this test exists: the
  clause below is reached by a malformed `terrain.game.get`, and the answer is the same one
  a track with no generated game gets.
  """
  use ExUnit.Case
  @moduletag :stores

  alias BotArmyTerrain.GameStateStore

  test "no track id is nil, not a query" do
    assert GameStateStore.get_by_track(BotArmyLibraryCore.Tenant.default_tenant_id(), nil) ==
             nil
  end
end
