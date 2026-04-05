defmodule BotArmyTerrain.ReviewSessionStoreBehaviour do
  @moduledoc """
  Behaviour for review session storage.
  """

  @callback create_session(tenant_id :: binary(), attrs :: map()) :: {:ok, any()} | {:error, any()}
  @callback end_session(tenant_id :: binary(), session_id :: binary()) :: {:ok, any()} | {:error, any()}
  @callback record_card_review(tenant_id :: binary(), user_id :: binary() | nil, attrs :: map()) :: {:ok, any()} | {:error, any()}
  @callback get_session_stats(tenant_id :: binary(), session_id :: binary()) :: {:ok, map()} | {:error, any()}
end
