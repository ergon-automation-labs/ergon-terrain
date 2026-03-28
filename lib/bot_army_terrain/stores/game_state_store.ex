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

  @doc "Get game state for a track (or nil if not generated)."
  def get_by_track(track_id) do
    Repo.get_by(GameState, track_id: track_id)
  end

  @doc "Create or update game state (upsert by track_id)."
  def upsert(attrs) do
    %GameState{}
    |> GameState.changeset(attrs)
    |> Repo.insert(
      on_conflict: :replace_all,
      conflict_target: :track_id
    )
  end

  @doc "Update only the status field for a track."
  def mark_status(track_id, status) do
    case Repo.get_by(GameState, track_id: track_id) do
      nil ->
        {:ok, %GameState{}}

      game_state ->
        game_state
        |> Ecto.Changeset.change(status: status)
        |> Repo.update()
    end
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end
end
