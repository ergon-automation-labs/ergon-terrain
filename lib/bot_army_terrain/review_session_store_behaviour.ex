defmodule BotArmyTerrain.ReviewSessionStoreBehaviour do
  @moduledoc """
  Behaviour for review session storage.
  """

  @callback create_session(attrs :: map()) :: {:ok, any()} | {:error, any()}
  @callback end_session(session_id :: binary()) :: {:ok, any()} | {:error, any()}
  @callback record_card_review(attrs :: map()) :: {:ok, any()} | {:error, any()}
  @callback get_session_stats(session_id :: binary()) :: {:ok, map()} | {:error, any()}
end
