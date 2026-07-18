defmodule BotArmyTerrain.Handlers.LlmResponseHandler do
  @moduledoc """
  Handle parsed LLM responses on events.llm.response.parsed.
  Filters by metadata["source"] == "terrain_card_generation" to avoid consuming other bots' responses.
  Extracts cards from structured_data["cards"] and creates Card records.
  """

  require Logger

  # Allow mocking via Application config (for tests)
  defp card_store, do: Application.get_env(:bot_army_terrain, :card_store, BotArmyTerrain.CardStore)
  defp track_store, do: Application.get_env(:bot_army_terrain, :track_store, BotArmyTerrain.TrackStore)
  defp embed_worker, do: Application.get_env(:bot_army_terrain, :embed_worker, BotArmyTerrain.EmbedWorker)

  @doc "Handle a parsed LLM response message."
  def handle_parsed(message) do
    %{tenant_id: tenant_id, user_id: user_id} = BotArmyLibraryCore.Tenant.extract_context(message)
    payload = message["payload"] || message

    # Check if this is a terrain card generation response
    case payload["metadata"] do
      %{"source" => "terrain_card_generation"} ->
        process_cards(tenant_id, user_id, payload)

      _ ->
        Logger.debug("Ignoring LLM response (not terrain_card_generation)")
        :ignore
    end
  end

  # Process cards from the LLM response
  defp process_cards(tenant_id, user_id, payload) do
    track_id = payload["metadata"]["track_id"]
    chunk_ids = payload["metadata"]["chunk_ids"] || []
    chunk_id = List.first(chunk_ids)
    model = payload["metadata"]["model"]

    case extract_cards(payload) do
      {:ok, cards} ->
        success_count = create_cards_for_track(tenant_id, track_id, chunk_id, cards, model)
        track_store().update_card_count_from_store(tenant_id, track_id)
        Logger.info("Created #{success_count} cards from LLM response for track #{track_id}")
        :ok

      {:error, reason} ->
        Logger.warning("Failed to extract cards from LLM response: #{inspect(reason)}")
        :error
    end
  end

  # Extract cards array from structured_data
  defp extract_cards(payload) do
    case payload["structured_data"] do
      %{"cards" => cards} when is_list(cards) ->
        {:ok, cards}

      _ ->
        {:error, :missing_cards}
    end
  end

  # Create cards for a track, return success count
  defp create_cards_for_track(tenant_id, track_id, chunk_id, cards, model) do
    cards
    |> Enum.map(fn card ->
      case validate_and_create_card(tenant_id, track_id, chunk_id, card, model) do
        {:ok, _} -> 1
        {:error, reason} ->
          Logger.warning("Failed to create card: #{inspect(reason)}")
          0
      end
    end)
    |> Enum.sum()
  end

  # Validate and create a single card
  defp validate_and_create_card(tenant_id, track_id, chunk_id, card_data, model) do
    front = card_data["front"]
    back = card_data["back"]
    card_type = card_data["card_type"] || "basic"

    cond do
      !is_binary(front) || front == "" ->
        {:error, :missing_front}

      !is_binary(back) || back == "" ->
        {:error, :missing_back}

      true ->
        attrs = %{
          track_id: track_id,
          chunk_id: chunk_id,
          front: front,
          back: back,
          card_type: normalize_card_type(card_type),
          generation_model: model
        }

        case card_store().create_card(tenant_id, attrs) do
          {:ok, card} ->
            embed_worker().queue_card(tenant_id, card.id)
            {:ok, card}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # Normalize card_type to valid values
  defp normalize_card_type(type) when is_binary(type) do
    case String.downcase(type) do
      "basic" -> "basic"
      "cloze" -> "cloze"
      "definition" -> "definition"
      _ -> "basic"
    end
  end

  defp normalize_card_type(_), do: "basic"
end
