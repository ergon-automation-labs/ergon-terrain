ExUnit.start()

# Mock modules for testing
Mox.defmock(BotArmyTerrain.CardStoreMock, for: BotArmyTerrain.CardStoreBehaviour)
Mox.defmock(BotArmyTerrain.TrackStoreMock, for: BotArmyTerrain.TrackStoreBehaviour)

# Configure app to use mocks in tests
Application.put_env(:bot_army_terrain, :card_store, BotArmyTerrain.CardStoreMock)
Application.put_env(:bot_army_terrain, :track_store, BotArmyTerrain.TrackStoreMock)
