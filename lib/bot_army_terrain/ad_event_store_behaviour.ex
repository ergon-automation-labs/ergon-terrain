defmodule BotArmyTerrain.AdEventStoreBehaviour do
  @moduledoc "The interstitials' event log: write one, read the last few by kind."

  @callback record(tenant_id :: binary(), attrs :: map()) :: {:ok, map()} | {:error, term()}
  @callback recent(tenant_id :: binary(), kind :: binary(), limit :: pos_integer()) :: [map()]
end
