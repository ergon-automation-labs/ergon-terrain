defmodule BotArmyTerrain.EmbedWorker do
  @moduledoc """
  Worker that queues cards for embedding generation.

  Receives card_ids and publishes embedding requests to the LLM bot via NATS.
  Uses fire-and-forget pattern - no ack needed, failures are logged but don't block.
  """

  use GenServer
  require Logger

  @behaviour BotArmyTerrain.EmbedWorkerBehaviour

  alias BotArmyTerrain.CardStore

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  @doc "Queue a card for embedding generation (fire-and-forget)."
  def queue_card(tenant_id, card_id) do
    GenServer.cast(__MODULE__, {:embed_card, tenant_id, card_id})
  end

  @impl true
  @doc "Queue a chunk for embedding generation (fire-and-forget)."
  def queue_chunk(tenant_id, chunk_id) do
    GenServer.cast(__MODULE__, {:embed_chunk, tenant_id, chunk_id})
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:embed_card, tenant_id, card_id}, state) do
    case CardStore.get_card(tenant_id, card_id) do
      nil ->
        Logger.warning("Card #{card_id} not found for embedding")
        {:noreply, state}

      card ->
        case publish_embed_request(card) do
          :ok ->
            Logger.debug("Queued embedding for card #{card_id}")
            {:noreply, state}

          {:error, reason} ->
            Logger.warning("Failed to queue embedding for card #{card_id}: #{inspect(reason)}")
            {:noreply, state}
        end
    end
  end

  def handle_cast({:embed_chunk, tenant_id, chunk_id}, state) do
    alias BotArmyTerrain.ChunkStore

    case ChunkStore.get(tenant_id, chunk_id) do
      nil ->
        Logger.warning("Chunk #{chunk_id} not found for embedding")
        {:noreply, state}

      chunk ->
        case publish_embed_request_for_chunk(chunk) do
          :ok ->
            Logger.debug("Queued embedding for chunk #{chunk_id}")
            {:noreply, state}

          {:error, reason} ->
            Logger.warning("Failed to queue embedding for chunk #{chunk_id}: #{inspect(reason)}")
            {:noreply, state}
        end
    end
  end

  # Private helpers

  defp publish_embed_request(card) do
    case get_connection() do
      {:ok, conn} ->
        subject = "llm.embed.request"

        payload = %{
          "text" => card.front <> " " <> card.back,
          "card_id" => card.id,
          "model" => "nomic-embed-text"
        }

        event = %{
          "event" => "llm.embed.request",
          "event_id" => Ecto.UUID.generate(),
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "source" => "bot_army_terrain",
          "source_node" => node() |> Atom.to_string(),
          "triggered_by" => "terrain.bot",
          "schema_version" => "1.0",
          "payload" => payload
        }

        case Gnat.pub(conn, subject, Jason.encode!(event)) do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp publish_embed_request_for_chunk(chunk) do
    case get_connection() do
      {:ok, conn} ->
        subject = "llm.embed.request"

        payload = %{
          "text" => chunk.content,
          "chunk_id" => chunk.id,
          "model" => "nomic-embed-text"
        }

        event = %{
          "event" => "llm.embed.request",
          "event_id" => Ecto.UUID.generate(),
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "source" => "bot_army_terrain",
          "source_node" => node() |> Atom.to_string(),
          "triggered_by" => "terrain.bot",
          "schema_version" => "1.0",
          "payload" => payload
        }

        case Gnat.pub(conn, subject, Jason.encode!(event)) do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_connection do
    try do
      GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 5000)
    rescue
      _ -> {:error, :unavailable}
    catch
      :exit, _ -> {:error, :unavailable}
    end
  end
end
