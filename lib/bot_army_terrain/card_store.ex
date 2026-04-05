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

  @doc "List all cards for a track, scoped to tenant."
  def list_cards_for_track(tenant_id, track_id, opts \\ []) do
    query = from c in Card, where: c.tenant_id == ^tenant_id and c.track_id == ^track_id, order_by: [asc: c.inserted_at]
    query = if Keyword.get(opts, :exclude_suspended, false), do: from(c in query, where: c.state != "suspended"), else: query
    Repo.all(query)
  end

  @doc "Get cards due for review (next_review_at <= now), optionally limit, scoped to tenant."
  def list_due_cards(tenant_id, track_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    now = DateTime.utc_now()

    from(c in Card,
      where: c.tenant_id == ^tenant_id and c.track_id == ^track_id and c.next_review_at <= ^now and c.state != "suspended",
      order_by: [asc: c.next_review_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc "Get a card by id, scoped to tenant."
  def get_card(tenant_id, id) do
    case Repo.get(Card, id) do
      nil -> nil
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

  @doc "Delete a card."
  def delete_card(card_id) do
    case Repo.get(Card, card_id) do
      nil -> {:error, :not_found}
      card -> Repo.delete(card)
    end
  end

  @doc "Count due cards for a track, scoped to tenant."
  def count_due_cards(tenant_id, track_id) do
    now = DateTime.utc_now()

    from(c in Card,
      where: c.tenant_id == ^tenant_id and c.track_id == ^track_id and c.next_review_at <= ^now and c.state != "suspended",
      select: count(c.id)
    )
    |> Repo.one()
  end

  @doc "Find similar cards by embedding vector (cosine distance), scoped to tenant."
  def find_similar_cards(tenant_id, track_id, query_vector, limit \\ 5) do
    from(c in Card,
      where: c.tenant_id == ^tenant_id and c.track_id == ^track_id and not is_nil(c.embedding_vector),
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
