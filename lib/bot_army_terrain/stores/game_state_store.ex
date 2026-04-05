defmodule BotArmyTerrain.GameStateStore do
  @moduledoc """
  Game state management: store pre-generated game + Dojo content per track.
  Handles generation status tracking (generating_game → generating_dojo → active).
  """

  use GenServer
  require Logger

  alias BotArmyTerrain.Repo
  alias BotArmyTerrain.Schemas.GameState

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get game state for a track, scoped to tenant (or nil if not generated)."
  def get_by_track(tenant_id, track_id) do
    case Repo.get_by(GameState, track_id: track_id) do
      nil -> nil
      game_state -> if game_state.tenant_id == tenant_id, do: game_state, else: nil
    end
  end

  @doc "Create or update game state (upsert by track_id), scoped to tenant."
  def upsert(tenant_id, attrs) do
    attrs = Map.put(attrs, :tenant_id, tenant_id)
    %GameState{}
    |> GameState.changeset(attrs)
    |> Repo.insert(
      on_conflict: :replace_all,
      conflict_target: :track_id
    )
  end

  @doc "Update only the status field for a track, scoped to tenant."
  def mark_status(tenant_id, track_id, status) do
    case Repo.get_by(GameState, track_id: track_id) do
      nil ->
        {:ok, %GameState{}}

      game_state ->
        if game_state.tenant_id == tenant_id do
          game_state
          |> Ecto.Changeset.change(status: status)
          |> Repo.update()
        else
          {:error, :unauthorized}
        end
    end
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end
end
