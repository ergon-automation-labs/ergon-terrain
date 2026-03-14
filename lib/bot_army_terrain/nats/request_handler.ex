defmodule BotArmyTerrain.NATS.RequestHandler do
  @moduledoc """
  NATS request/reply handler for terrain surface queries.

  Handles:
  - terrain.tracks.list → {tracks: [...]}
  - terrain.cards.due → {cards: [...]}
  - terrain.review.submit → fire-and-forget
  """

  use GenServer
  require Logger

  alias BotArmyTerrain.{TrackStore, CardStore}

  @reconnect_delay_ms 5000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    state = %{subscriptions: [], opts: opts}
    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case get_connection() do
      {:ok, conn} -> subscribe(conn, state)
      {:error, _} -> schedule_reconnect(state)
    end
  end

  @impl true
  def handle_info({:msg, %{topic: topic, body: body, reply_to: reply_to}}, state) do
    Logger.debug("Terrain RequestHandler: #{topic}")

    case decode(body) do
      {:ok, msg} ->
        response = handle_request(topic, msg)
        send_reply(state, reply_to, response)

      {:error, reason} ->
        Logger.warning("Terrain decode failed: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:msg, %{topic: topic, body: body}}, state) do
    Logger.debug("Terrain RequestHandler (no reply): #{topic}")

    case decode(body) do
      {:ok, msg} -> handle_event(topic, msg)
      {:error, reason} -> Logger.warning("Terrain decode failed: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:connect_retry, state) do
    {:noreply, state, {:continue, :connect}}
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

  defp subscribe(conn, state) do
    subscriptions = [
      "terrain.tracks.list",
      "terrain.cards.due",
      "terrain.review.submit"
    ]

    results =
      Enum.map(subscriptions, fn subject ->
        case Gnat.sub(conn, self(), subject) do
          {:ok, sub} ->
            Logger.info("Terrain subscribed to #{subject}")
            sub

          {:error, reason} ->
            Logger.error("Terrain subscribe to #{subject} failed: #{inspect(reason)}")
            nil
        end
      end)

    if Enum.all?(results, &(&1 != nil)) do
      {:noreply, %{state | subscriptions: results}}
    else
      schedule_reconnect(state)
    end
  end

  defp schedule_reconnect(state) do
    Process.send_after(self(), :connect_retry, @reconnect_delay_ms)
    {:noreply, state}
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, map} -> {:ok, map}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp handle_request("terrain.tracks.list", _msg) do
    tracks = TrackStore.list_tracks(status: "active")

    track_list =
      Enum.map(tracks, fn track ->
        cards_due = CardStore.count_due_cards(track.id)

        %{
          "id" => track.id,
          "name" => track.name,
          "card_count" => track.card_count || 0,
          "cards_due" => cards_due || 0,
          "status" => track.status,
          "last_reviewed_at" => track.updated_at && DateTime.to_iso8601(track.updated_at)
        }
      end)

    Jason.encode!(%{"tracks" => track_list})
  end

  defp handle_request("terrain.cards.due", msg) do
    track_id = msg["track_id"]

    if track_id do
      cards = CardStore.list_due_cards(track_id, limit: 20)

      card_list =
        Enum.map(cards, fn card ->
          %{
            "id" => card.id,
            "front" => card.front,
            "back" => card.back
          }
        end)

      Jason.encode!(%{"cards" => card_list})
    else
      Jason.encode!(%{"error" => "track_id required", "cards" => []})
    end
  end

  defp handle_request(topic, _msg) do
    Logger.warning("Unknown request topic: #{topic}")
    Jason.encode!(%{"error" => "unknown topic"})
  end

  defp handle_event("terrain.review.submit", msg) do
    session_id = msg["session_id"]
    _track_id = msg["track_id"]
    card_id = msg["card_id"]
    quality = msg["quality"]
    elapsed_ms = msg["elapsed_ms"]

    Logger.info("Terrain review: session=#{session_id}, card=#{card_id}, quality=#{quality}, elapsed=#{elapsed_ms}ms")

    # TODO: Record review result in database and update card SRS fields
    # For now, just log it
    :ok
  end

  defp send_reply(_state, reply_to, response) do
    case get_connection() do
      {:ok, conn} ->
        case Gnat.pub(conn, reply_to, response) do
          :ok -> :ok
          {:error, reason} -> Logger.error("Failed to send reply: #{inspect(reason)}")
        end

      {:error, _} ->
        Logger.error("Cannot send reply: NATS disconnected")
    end
  end
end
