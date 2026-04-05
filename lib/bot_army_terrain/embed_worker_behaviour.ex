defmodule BotArmyTerrain.EmbedWorkerBehaviour do
  @moduledoc """
  Behaviour for embed worker.
  """

  @callback queue_card(tenant_id :: binary(), card_id :: binary()) :: :ok
  @callback queue_chunk(tenant_id :: binary(), chunk_id :: binary()) :: :ok
end
