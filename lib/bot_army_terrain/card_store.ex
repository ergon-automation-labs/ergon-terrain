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

  @doc "List all cards for a track."
  def list_cards_for_track(track_id, opts \\ []) do
    query = from c in Card, where: c.track_id == ^track_id, order_by: [asc: c.inserted_at]
    query = if Keyword.get(opts, :exclude_suspended, false), do: from(c in query, where: c.state != "suspended"), else: query
    Repo.all(query)
  end

  @doc "Get cards due for review (next_review_at <= now), optionally limit."
  def list_due_cards(track_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    now = DateTime.utc_now()

    from(c in Card,
      where: c.track_id == ^track_id and c.next_review_at <= ^now and c.state != "suspended",
      order_by: [asc: c.next_review_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc "Get a card by id."
  def get_card(id), do: Repo.get(Card, id)

  @doc "Create a card."
  def create_card(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    %Card{}
    |> Card.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Update a card (e.g., SRS fields after review)."
  def update_card(card, attrs) do
    card
    |> Card.changeset(attrs)
    |> Repo.update()
  end

  @doc "Delete a card."
  def delete_card(card_id) do
    case Repo.get(Card, card_id) do
      nil -> {:error, :not_found}
      card -> Repo.delete(card)
    end
  end

  @doc "Count due cards for a track."
  def count_due_cards(track_id) do
    now = DateTime.utc_now()

    from(c in Card,
      where: c.track_id == ^track_id and c.next_review_at <= ^now and c.state != "suspended",
      select: count(c.id)
    )
    |> Repo.one()
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end
end
