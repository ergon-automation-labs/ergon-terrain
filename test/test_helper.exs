ExUnit.configure(exclude: [:integration, :load, :nats_live])
ExUnit.start()

# Mock modules for testing
Mox.defmock(BotArmyTerrain.CardStoreMock, for: BotArmyTerrain.CardStoreBehaviour)
Mox.defmock(BotArmyTerrain.TrackStoreMock, for: BotArmyTerrain.TrackStoreBehaviour)

Mox.defmock(BotArmyTerrain.ReviewSessionStoreMock,
  for: BotArmyTerrain.ReviewSessionStoreBehaviour
)

Mox.defmock(BotArmyTerrain.EmbedWorkerMock, for: BotArmyTerrain.EmbedWorkerBehaviour)
Mox.defmock(BotArmyTerrain.StoryStoreMock, for: BotArmyTerrain.StoryStoreBehaviour)
Mox.defmock(BotArmyTerrain.PitchStoreMock, for: BotArmyTerrain.PitchStoreBehaviour)
Mox.defmock(BotArmyTerrain.AdEventStoreMock, for: BotArmyTerrain.AdEventStoreBehaviour)

# Configure app to use mocks in tests
Application.put_env(:bot_army_terrain, :card_store, BotArmyTerrain.CardStoreMock)
Application.put_env(:bot_army_terrain, :track_store, BotArmyTerrain.TrackStoreMock)

Application.put_env(
  :bot_army_terrain,
  :review_session_store,
  BotArmyTerrain.ReviewSessionStoreMock
)

Application.put_env(:bot_army_terrain, :embed_worker, BotArmyTerrain.EmbedWorkerMock)
Application.put_env(:bot_army_terrain, :story_store, BotArmyTerrain.StoryStoreMock)
Application.put_env(:bot_army_terrain, :pitch_store, BotArmyTerrain.PitchStoreMock)
Application.put_env(:bot_army_terrain, :ad_event_store, BotArmyTerrain.AdEventStoreMock)
