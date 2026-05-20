defmodule BotArmyTerrain.TrackStoreBehaviour do
  @moduledoc "Behaviour contract for learning track storage implementations."
  @doc "Get or create a track by name"
  @callback get_or_create_track_by_name(name :: String.t()) :: {:ok, any} | {:error, any}

  @doc "Update track card count from store"
  @callback update_card_count_from_store(tenant_id :: String.t(), track_id :: String.t()) ::
              {:ok, any} | {:error, any}
end
