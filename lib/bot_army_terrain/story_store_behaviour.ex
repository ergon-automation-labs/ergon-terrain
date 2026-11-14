defmodule BotArmyTerrain.StoryStoreBehaviour do
  @moduledoc "Behaviour contract for story progress storage."

  @doc "The tenant's progress as a plain map, or nil when the story has not started"
  @callback get(tenant_id :: binary) :: map | nil

  @doc "Write the tenant's progress (insert or replace)"
  @callback put(tenant_id :: binary, progress :: map) :: {:ok, map} | {:error, any}
end
