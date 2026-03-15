defmodule BotArmyTerrain.CardStoreBehaviour do
  @doc "Create a card"
  @callback create_card(attrs :: map) :: {:ok, any} | {:error, any}

  @doc "Get a card by id"
  @callback get_card(id :: binary) :: any | nil

  @doc "Update a card (e.g., SRS fields after review)"
  @callback update_card(card :: any, attrs :: map) :: {:ok, any} | {:error, any}
end
