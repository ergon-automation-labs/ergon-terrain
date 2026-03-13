defmodule BotArmyTerrain.NATS.Consumer do
  @moduledoc """
  NATS consumer for Terrain.

  Subscribes to:
  - bot.army.terrain.command.ingest — trigger ingestion (CSV, markdown, etc.)
  """

  use GenServer
  require Logger

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
  def handle_info({:msg, %{topic: topic, body: body}}, state) do
    Logger.debug("Terrain received NATS: #{topic}")

    case decode(body) do
      {:ok, msg} -> handle_command(topic, msg)
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
    subject = "bot.army.terrain.command.ingest"

    case Gnat.sub(conn, self(), subject) do
      {:ok, sub} ->
        Logger.info("Terrain subscribed to #{subject}")
        {:noreply, %{state | subscriptions: [sub]}}

      {:error, reason} ->
        Logger.error("Terrain subscribe failed: #{inspect(reason)}")
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

  defp handle_command("bot.army.terrain.command.ingest", msg) do
    payload = msg["payload"] || msg
    path = payload["path_or_blob_ref"] || payload["path"]
    source_type = (payload["source_type"] || "csv") |> to_string() |> String.downcase()

    case source_type do
      "csv" when is_binary(path) and path != "" ->
        case BotArmyTerrain.Ingestion.IngestionWorker.ingest_csv(path) do
          {:ok, stats} -> Logger.info("Terrain ingest completed: #{inspect(stats)}")
          {:error, reason} -> Logger.error("Terrain ingest failed: #{inspect(reason)}")
        end

      _ ->
        Logger.info("Terrain ingest: unsupported source_type=#{source_type} or missing path")
    end
  end

  defp handle_command(_topic, _msg), do: :ok
end
