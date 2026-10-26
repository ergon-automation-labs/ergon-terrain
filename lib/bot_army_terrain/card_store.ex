defmodule BotArmyTerrain.CardStore do
  @moduledoc """
  Card management: create, list, get by id, update SRS fields.
  """

  use GenServer
  require Logger
  import Ecto.Query

  alias BotArmyTerrain.Repo
  alias BotArmyTerrain.Schemas.Card

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "List all cards for a track, scoped to tenant. Removed cards are not listed."
  def list_cards_for_track(tenant_id, track_id, opts \\ []) do
    query =
      from c in Card,
        where:
          c.tenant_id == ^tenant_id and c.track_id == ^track_id and is_nil(c.deleted_at),
        order_by: [asc: c.inserted_at]

    query = if Keyword.get(opts, :exclude_suspended, false), do: from(c in query, where: c.state != "suspended"), else: query
    Repo.all(query)
  end

  @doc "Get cards due for review (next_review_at <= now), optionally limit, scoped to tenant."
  def list_due_cards(tenant_id, track_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    now = DateTime.utc_now()

    from(c in Card,
      where:
        c.tenant_id == ^tenant_id and c.track_id == ^track_id and
          c.next_review_at <= ^now and c.state != "suspended" and is_nil(c.deleted_at),
      order_by: [asc: c.next_review_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Get a card by id, scoped to tenant.

  A removed card reads as absent: nothing that reviews, edits, or deletes a card should find
  one that is not on the deck. `restore_card/2` is the one door that looks behind the mark.
  """
  def get_card(tenant_id, id) do
    case Repo.get(Card, id) do
      nil -> nil
      %Card{deleted_at: deleted_at} when not is_nil(deleted_at) -> nil
      card -> if card.tenant_id == tenant_id, do: card, else: nil
    end
  end

  @doc "Create a card with tenant stamping."
  def create_card(tenant_id, attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    attrs = Map.put(attrs, "tenant_id", tenant_id)
    %Card{}
    |> Card.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Update a card (e.g., SRS fields after review), scoped to tenant."
  def update_card(tenant_id, card, attrs) do
    if card.tenant_id == tenant_id do
      card
      |> Card.changeset(attrs)
      |> Repo.update()
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Remove a card from its deck — a mark, not a delete.

  The row stays, with `deleted_at` set, so `restore_card/2` can put it back with the review
  history it had. Every read filters the mark, so from outside the deck this is a removal.
  """
  def delete_card(card_id) do
    case Repo.get(Card, card_id) do
      nil ->
        {:error, :not_found}

      %Card{deleted_at: deleted_at} when not is_nil(deleted_at) ->
        {:error, :not_found}

      card ->
        card
        |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
        |> Repo.update()
    end
  end

  @doc """
  Put a removed card back on its deck, scoped to tenant.

  Clearing the mark is the whole undo: the row never lost its ease factor, interval, or last
  review, so a card that comes back is the card she knew, not a new one that has forgotten.
  A card that was never removed is not an error — it is already where she wants it.
  """
  def restore_card(tenant_id, card_id) when is_binary(card_id) do
    case Repo.get(Card, card_id) do
      nil ->
        {:error, :not_found}

      %Card{tenant_id: owner} when owner != tenant_id ->
        {:error, :not_found}

      %Card{deleted_at: nil} = card ->
        {:ok, card}

      card ->
        card
        |> Ecto.Changeset.change(deleted_at: nil)
        |> Repo.update()
    end
  end

  @doc "Count due cards for a track, scoped to tenant."
  def count_due_cards(tenant_id, track_id) do
    now = DateTime.utc_now()

    from(c in Card,
      where:
        c.tenant_id == ^tenant_id and c.track_id == ^track_id and
          c.next_review_at <= ^now and c.state != "suspended" and is_nil(c.deleted_at),
      select: count(c.id)
    )
    |> Repo.one()
  end

  @doc "Find similar cards by embedding vector (cosine distance), scoped to tenant."
  def find_similar_cards(tenant_id, track_id, query_vector, limit \\ 5) do
    from(c in Card,
      where:
        c.tenant_id == ^tenant_id and c.track_id == ^track_id and
          not is_nil(c.embedding_vector) and is_nil(c.deleted_at),
      select: %{
        id: c.id,
        front: c.front,
        back: c.back,
        similarity: fragment("1 - (? <=> ?)", c.embedding_vector, ^query_vector)
      },
      order_by: [desc: fragment("1 - (? <=> ?)", c.embedding_vector, ^query_vector)],
      limit: ^limit
    )
    |> Repo.all()
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end
end
