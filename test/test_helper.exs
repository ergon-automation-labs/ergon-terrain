ExUnit.configure(exclude: [:integration, :load, :nats_live])
ExUnit.start()

# Mock modules for testing
Mox.defmock(BotArmyTerrain.CardStoreMock, for: BotArmyTerrain.CardStoreBehaviour)
Mox.defmock(BotArmyTerrain.TrackStoreMock, for: BotArmyTerrain.TrackStoreBehaviour)
Mox.defmock(BotArmyTerrain.ReviewSessionStoreMock, for: BotArmyTerrain.ReviewSessionStoreBehaviour)
Mox.defmock(BotArmyTerrain.EmbedWorkerMock, for: BotArmyTerrain.EmbedWorkerBehaviour)

# Configure app to use mocks in tests
Application.put_env(:bot_army_terrain, :card_store, BotArmyTerrain.CardStoreMock)
Application.put_env(:bot_army_terrain, :track_store, BotArmyTerrain.TrackStoreMock)
Application.put_env(:bot_army_terrain, :review_session_store, BotArmyTerrain.ReviewSessionStoreMock)
Application.put_env(:bot_army_terrain, :embed_worker, BotArmyTerrain.EmbedWorkerMock)
