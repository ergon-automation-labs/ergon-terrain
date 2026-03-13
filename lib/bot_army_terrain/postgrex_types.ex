# Defines BotArmyTerrain.PostgrexTypes via Postgrex.Types.define (pgvector + Ecto).
# Do not wrap in defmodule PostgrexTypes — define() creates that module.
defmodule BotArmyTerrain.PostgrexTypesSetup do
  Postgrex.Types.define(
    BotArmyTerrain.PostgrexTypes,
    Pgvector.extensions() ++ Ecto.Adapters.Postgres.extensions(),
    []
  )
end
