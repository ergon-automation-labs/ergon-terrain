defmodule BotArmyTerrain.Handlers.ReviewHandler do
  @moduledoc """
  Handles review submissions from the terrain surface.

  Processes review quality ratings and updates card SRS fields using the SM-2 algorithm.
  """

  require Logger

  alias BotArmyTerrain.SM2

  @doc """
  Handle a review submission message.

  Extracts card_id and quality from the message, looks up the card, applies SM-2
  scheduling, and persists the updated SRS fields.

  Args:
    - message: Map with keys "card_id" (binary), "quality" (0-5), and optional metadata

  Returns:
    - :ok on success
    - {:error, reason} on failure
  """
  def handle_submit(message) do
    with {:ok, card_id} <- extract_card_id(message),
         {:ok, quality} <- extract_quality(message),
         {:ok, card} <- fetch_card(card_id),
         {:ok, new_fields} <- apply_sm2(card, quality),
         :ok <- persist_card(card, new_fields) do
      log_review(card_id, quality, new_fields)
      record_card_review(message)
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract_card_id(message) do
    case message["card_id"] do
      nil -> {:error, :missing_card_id}
      id when is_binary(id) -> {:ok, id}
      _ -> {:error, :invalid_card_id}
    end
  end

  defp extract_quality(message) do
    case message["quality"] do
      nil -> {:error, :missing_quality}
      quality when is_integer(quality) and quality >= 0 and quality <= 5 -> {:ok, quality}
      quality when is_float(quality) and quality >= 0.0 and quality <= 5.0 ->
        {:ok, trunc(quality)}
      _ -> {:error, :invalid_quality}
    end
  end

  defp fetch_card(card_id) do
    card_store = Application.get_env(:bot_army_terrain, :card_store, BotArmyTerrain.CardStore)

    case card_store.get_card(card_id) do
      nil -> {:error, :card_not_found}
      card -> {:ok, card}
    end
  end

  defp apply_sm2(card, quality) do
    {:ok, SM2.schedule(card, quality)}
  end

  defp persist_card(card, new_fields) do
    card_store = Application.get_env(:bot_army_terrain, :card_store, BotArmyTerrain.CardStore)

    case card_store.update_card(card, new_fields) do
      {:ok, _updated_card} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp log_review(card_id, quality, fields) do
    Logger.info(
      "Review: card=#{card_id} quality=#{quality} → " <>
        "interval=#{fields.interval_days}d state=#{fields.state}"
    )
  end

  defp record_card_review(message) do
    case message["session_id"] do
      nil ->
        :ok

      session_id ->
        store = Application.get_env(:bot_army_terrain, :review_session_store, BotArmyTerrain.ReviewSessionStore)

        case store.record_card_review(message) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("Failed to record card review for session #{session_id}: #{inspect(reason)}")
            :ok
        end
    end
  end
end
