defmodule BotArmyTerrain.TrackStoreBehaviour do
  @moduledoc "Behaviour contract for learning track storage implementations."
  @doc "Get or create a track by name"
  @callback get_or_create_track_by_name(name :: String.t()) :: {:ok, any} | {:error, any}

  @doc "Update track card count from store"
  @callback update_card_count_from_store(tenant_id :: String.t(), track_id :: String.t()) ::
              {:ok, any} | {:error, any}

  @doc "Get a track by id, or nil"
  @callback get_track(id :: String.t()) :: any | nil

  @doc "Find a track by its exact name, or nil"
  @callback get_by_name(name :: String.t()) :: any | nil

  @doc "Create a track"
  @callback create_track(attrs :: map | keyword) :: {:ok, any} | {:error, any}

  @doc "Rename a track or change its description"
  @callback update_track(track :: any, attrs :: map) :: {:ok, any} | {:error, any}
end
