defmodule BotArmyTerrain.CardStoreBehaviour do
  @moduledoc "Behaviour contract for flashcard storage implementations."
  @doc "Create a card"
  @callback create_card(tenant_id :: binary, attrs :: map) :: {:ok, any} | {:error, any}

  @doc "Get a card by id, scoped to tenant"
  @callback get_card(tenant_id :: binary, id :: binary) :: any | nil

  @doc "Update a card (e.g., SRS fields after review)"
  @callback update_card(tenant_id :: binary, card :: any, attrs :: map) ::
              {:ok, any} | {:error, any}

  @doc """
  Cards due for review in one track, next review first, scoped to tenant.

  `terrain.cards.due` calls this. It is in the behaviour because the request handler reads
  the store through the app env so the clause can be tested without a database — and a mock
  can only answer a callback the behaviour declares.
  """
  @callback list_due_cards(tenant_id :: binary, track_id :: binary, opts :: keyword) :: list
end
