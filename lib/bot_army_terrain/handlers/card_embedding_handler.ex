defmodule BotArmyTerrain.Handlers.CardEmbeddingHandler do
  @moduledoc """
  Handles embedding events from the LLM bot.

  Receives `events.llm.embedding.created` and updates cards with their embedding vectors.
  """

  require Logger

  alias BotArmyTerrain.CardStore

  @doc "Handle embedding created event from LLM bot."
  def handle_embedding(message) do
    %{tenant_id: tenant_id, user_id: user_id} = BotArmyLibraryCore.Tenant.extract_context(message)
    payload = message["payload"]

    case extract_embedding_data(payload) do
      {:ok, card_id, embedding} ->
        update_card_embedding(tenant_id, user_id, card_id, embedding)

      {:error, reason} ->
        Logger.warning("Invalid embedding data: #{inspect(reason)}")
    end
  end

  # Private helpers

  defp extract_embedding_data(payload) when is_map(payload) do
    with card_id when is_binary(card_id) <- payload["card_id"],
         embedding when is_list(embedding) <- payload["embedding"],
         true <- Enum.all?(embedding, &is_float/1) do
      {:ok, card_id, embedding}
    else
      _ -> {:error, :invalid_embedding_data}
    end
  end

  defp extract_embedding_data(_) do
    {:error, :invalid_payload}
  end

  defp update_card_embedding(tenant_id, user_id, card_id, embedding) do
    case CardStore.get_card(tenant_id, card_id) do
      nil ->
        Logger.warning("Card #{card_id} not found for embedding update")
        :ok

      card ->
        vector = Pgvector.new(embedding)

        case CardStore.update_card(tenant_id, card, %{
          embedding_vector: vector,
          embedded_at: DateTime.utc_now()
        }) do
          {:ok, _} ->
            Logger.debug("Updated embedding for card #{card_id}")
            :ok

          {:error, reason} ->
            Logger.error("Failed to update card #{card_id} with embedding: #{inspect(reason)}")
            :ok
        end
    end
  end
end
