defmodule BotArmyTerrain.CardStoreBehaviour do
  @moduledoc "Behaviour contract for flashcard storage implementations."
  @doc "Create a card"
  @callback create_card(tenant_id :: binary, attrs :: map) :: {:ok, any} | {:error, any}

  @doc "Get a card by id, scoped to tenant"
  @callback get_card(tenant_id :: binary, id :: binary) :: any | nil

  @doc "Update a card (e.g., SRS fields after review)"
  @callback update_card(tenant_id :: binary, card :: any, attrs :: map) ::
              {:ok, any} | {:error, any}
end
