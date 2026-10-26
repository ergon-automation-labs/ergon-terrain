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

  @doc """
  Every card in one track, oldest first, scoped to tenant.

  The management door reads this rather than `list_due_cards/3`: a deck is edited on the days
  nothing is due, so a list of what is *due* is the wrong list to manage.
  """
  @callback list_cards_for_track(tenant_id :: binary, track_id :: binary) :: list

  @doc "Remove one card by id — a mark, not a delete; `restore_card/2` puts it back."
  @callback delete_card(card_id :: binary) :: {:ok, any} | {:error, any}

  @doc """
  Put a removed card back on its deck, scoped to tenant.

  The undo the management page draws after a removal. It clears the mark the delete set, so the
  row that comes back is the row that left: its scheduling, its history, its id.
  """
  @callback restore_card(tenant_id :: binary, card_id :: binary) :: {:ok, any} | {:error, any}
end
