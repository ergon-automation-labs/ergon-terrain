defmodule BotArmyTerrain.Handlers.SessionHandler do
  @moduledoc """
  Handles review session start/end requests.
  """

  require Logger

  @doc "Handle session start request, returns {session_id}."
  def handle_start(message) do
    with {:ok, track_id} <- extract_track_id(message),
         {:ok, session} <- create_session(track_id) do
      Jason.encode!(%{"session_id" => session.id})
    else
      {:error, reason} ->
        Logger.error("Session start failed: #{inspect(reason)}")
        Jason.encode!(%{"error" => inspect(reason)})
    end
  end

  @doc "Handle session end request, returns stats."
  def handle_end(message) do
    with {:ok, session_id} <- extract_session_id(message),
         {:ok, stats} <- get_session_stats(session_id),
         :ok <- end_session_in_store(session_id) do
      Jason.encode!(stats)
    else
      {:error, reason} ->
        Logger.error("Session end failed: #{inspect(reason)}")
        Jason.encode!(%{"error" => inspect(reason)})
    end
  end

  # Private helpers

  defp extract_track_id(message) do
    case message["track_id"] do
      nil -> {:error, :missing_track_id}
      id when is_binary(id) -> {:ok, id}
      _ -> {:error, :invalid_track_id}
    end
  end

  defp extract_session_id(message) do
    case message["session_id"] do
      nil -> {:error, :missing_session_id}
      id when is_binary(id) -> {:ok, id}
      _ -> {:error, :invalid_session_id}
    end
  end

  defp create_session(track_id) do
    store = Application.get_env(:bot_army_terrain, :review_session_store, BotArmyTerrain.ReviewSessionStore)
    store.create_session(%{track_id: track_id})
  end

  defp end_session_in_store(session_id) do
    store = Application.get_env(:bot_army_terrain, :review_session_store, BotArmyTerrain.ReviewSessionStore)

    case store.end_session(session_id) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_session_stats(session_id) do
    store = Application.get_env(:bot_army_terrain, :review_session_store, BotArmyTerrain.ReviewSessionStore)
    store.get_session_stats(session_id)
  end
end
