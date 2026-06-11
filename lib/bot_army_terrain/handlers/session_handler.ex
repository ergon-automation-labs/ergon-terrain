defmodule BotArmyTerrain.Handlers.SessionHandler do
  @moduledoc """
  Handles review session start/end requests.
  """

  require Logger

  @doc "Handle session start request, returns {session_id}."
  def handle_start(message) do
    %{tenant_id: tenant_id, user_id: user_id} = BotArmyCore.Tenant.extract_context(message)

    with {:ok, track_id} <- extract_track_id(message),
         {:ok, session} <- create_session(tenant_id, track_id) do
      BotArmyRuntime.Outcomes.emit("terrain", "session", "session_started", 1,
        metadata: %{session_id: session.id, track_id: track_id, tenant_id: tenant_id}
      )

      BotArmyRuntime.NATS.Reply.ok(%{
        "session_id" => session.id,
        "tenant_id" => tenant_id,
        "user_id" => user_id
      })
    else
      {:error, reason} ->
        Logger.error("Session start failed: #{inspect(reason)}")

        BotArmyRuntime.Outcomes.emit("terrain", "session", "session_start_failed", 0,
          metadata: %{reason: inspect(reason), tenant_id: tenant_id}
        )

        BotArmyRuntime.NATS.Reply.error(inspect(reason), :session_start_failed)
    end
  end

  @doc "Handle session end request, returns stats."
  def handle_end(message) do
    %{tenant_id: tenant_id, user_id: user_id} = BotArmyCore.Tenant.extract_context(message)

    with {:ok, session_id} <- extract_session_id(message),
         {:ok, stats} <- get_session_stats(tenant_id, session_id),
         :ok <- end_session_in_store(tenant_id, session_id) do
      BotArmyRuntime.Outcomes.emit("terrain", "session", "session_ended", 1,
        metadata: %{session_id: session_id, tenant_id: tenant_id, stats: inspect(stats)}
      )

      BotArmyRuntime.NATS.Reply.ok(
        Map.merge(stats, %{"tenant_id" => tenant_id, "user_id" => user_id})
      )
    else
      {:error, reason} ->
        Logger.error("Session end failed: #{inspect(reason)}")

        BotArmyRuntime.Outcomes.emit("terrain", "session", "session_end_failed", 0,
          metadata: %{reason: inspect(reason), tenant_id: tenant_id}
        )

        BotArmyRuntime.NATS.Reply.error(inspect(reason), :session_end_failed)
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

  defp create_session(tenant_id, track_id) do
    store =
      Application.get_env(
        :bot_army_terrain,
        :review_session_store,
        BotArmyTerrain.ReviewSessionStore
      )

    store.create_session(tenant_id, %{track_id: track_id})
  end

  defp end_session_in_store(tenant_id, session_id) do
    store =
      Application.get_env(
        :bot_army_terrain,
        :review_session_store,
        BotArmyTerrain.ReviewSessionStore
      )

    case store.end_session(tenant_id, session_id) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_session_stats(tenant_id, session_id) do
    store =
      Application.get_env(
        :bot_army_terrain,
        :review_session_store,
        BotArmyTerrain.ReviewSessionStore
      )

    store.get_session_stats(tenant_id, session_id)
  end
end
