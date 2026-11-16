defmodule BotArmyTerrain.PitchStoreBehaviour do
  @moduledoc "The purpose spots' small store: read one, read all, write one."

  @callback get(tenant_id :: binary(), project_id :: binary()) :: map() | nil
  @callback all(tenant_id :: binary()) :: [map()]
  @callback put(tenant_id :: binary(), project_id :: binary(), attrs :: map()) ::
              {:ok, map()} | {:error, term()}
end
