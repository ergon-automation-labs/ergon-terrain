defmodule BotArmyTerrain.CardStoreBehaviour do
  @doc "Create a card"
  @callback create_card(attrs :: map) :: {:ok, any} | {:error, any}
end
