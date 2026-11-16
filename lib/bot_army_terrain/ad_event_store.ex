defmodule BotArmyTerrain.AdEventStore do
  @moduledoc """
  Interstitial events in Postgres, read and written as plain maps.

  A record is idempotent by `(tenant, creative, kind, boundary)`: the boundary is a page she
  can refresh, and a second impression is not a second airing. `recent/3` is newest first and
  is what the silence rule reads.
  """

  @behaviour BotArmyTerrain.AdEventStoreBehaviour

  import Ecto.Query

  alias BotArmyTerrain.Repo
  alias BotArmyTerrain.Schemas.AdEvent

  @fields AdEvent.fields() ++ [:inserted_at]

  @impl true
  def record(tenant_id, attrs) do
    attrs =
      attrs
      |> Map.take(AdEvent.fields())
      |> Map.put(:tenant_id, tenant_id)

    %AdEvent{}
    |> AdEvent.changeset(attrs)
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:tenant_id, :creative_id, :kind, :boundary_key]
    )
    |> case do
      {:ok, event} -> {:ok, Map.take(event, @fields)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @impl true
  def recent(tenant_id, kind, limit) when is_integer(limit) and limit > 0 do
    from(event in AdEvent,
      where: event.tenant_id == ^tenant_id and event.kind == ^kind,
      order_by: [desc: event.inserted_at, desc: event.id],
      limit: ^limit
    )
    |> Repo.all()
    |> Enum.map(&Map.take(&1, @fields))
  end
end
