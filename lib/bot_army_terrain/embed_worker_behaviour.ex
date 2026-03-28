defmodule BotArmyTerrain.EmbedWorkerBehaviour do
  @moduledoc """
  Behaviour for embed worker.
  """

  @callback queue_card(card_id :: binary()) :: :ok
  @callback queue_chunk(chunk_id :: binary()) :: :ok
end
