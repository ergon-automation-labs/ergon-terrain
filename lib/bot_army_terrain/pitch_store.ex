defmodule BotArmyTerrain.PitchStore do
  @moduledoc """
  Purpose spots in Postgres: one row per tenant and project, read and written as a plain map.

  A write is a merge, not a replacement — `record` sends only the fields an event
  changes, and the row keeps the rest.
  """

  @behaviour BotArmyTerrain.PitchStoreBehaviour

  import Ecto.Query

  alias BotArmyTerrain.Repo
  alias BotArmyTerrain.Schemas.Pitch

  @fields Pitch.fields()

  @impl true
  def get(tenant_id, project_id) do
    case Repo.get_by(Pitch, tenant_id: tenant_id, project_id: project_id) do
      nil -> nil
      row -> Map.take(row, @fields)
    end
  end

  @impl true
  def all(tenant_id) do
    from(p in Pitch, where: p.tenant_id == ^tenant_id)
    |> Repo.all()
    |> Enum.map(&Map.take(&1, @fields))
  end

  @impl true
  def put(tenant_id, project_id, attrs) do
    row = Repo.get_by(Pitch, tenant_id: tenant_id, project_id: project_id) || %Pitch{}

    attrs =
      attrs
      |> Map.take(@fields)
      |> Map.put(:tenant_id, tenant_id)
      |> Map.put(:project_id, project_id)

    case row |> Pitch.changeset(attrs) |> Repo.insert_or_update() do
      {:ok, saved} -> {:ok, Map.take(saved, @fields)}
      {:error, changeset} -> {:error, changeset}
    end
  end
end
