defmodule BotArmyTerrain.StoryStore do
  @moduledoc "Story progress in Postgres: one row per tenant, read and written as a plain map."

  @behaviour BotArmyTerrain.StoryStoreBehaviour

  alias BotArmyTerrain.Repo
  alias BotArmyTerrain.Schemas.StoryProgress

  @fields [:chapter, :scene_id, :facts, :log, :chosen_on, :last_outcome]

  @impl true
  def get(tenant_id) do
    case Repo.get_by(StoryProgress, tenant_id: tenant_id) do
      nil -> nil
      row -> Map.take(row, @fields)
    end
  end

  @impl true
  def put(tenant_id, progress) do
    row = Repo.get_by(StoryProgress, tenant_id: tenant_id) || %StoryProgress{}
    attrs = progress |> Map.take(@fields) |> Map.put(:tenant_id, tenant_id)

    case row |> StoryProgress.changeset(attrs) |> Repo.insert_or_update() do
      {:ok, saved} -> {:ok, Map.take(saved, @fields)}
      {:error, changeset} -> {:error, changeset}
    end
  end
end
