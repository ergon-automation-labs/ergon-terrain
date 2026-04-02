defmodule BotArmyTerrain.TerrainBot do
  @moduledoc """
  Terrain Bot harness using BotArmy.GenBot.

  Handles skill-based command routing for terrain (topic learning):
  - Ingest CSV/markdown content
  - Generate flashcards from text
  - Import pre-made card decks

  LLM events (embeddings, completions) are handled separately by EventHandler.
  """

  use BotArmy.GenBot,
    skills: [
      BotArmyTerrain.Skills.Ingest,
      BotArmyTerrain.Skills.GenerateCards,
      BotArmyTerrain.Skills.ImportCards
    ],
    bot_id: :terrain
end
