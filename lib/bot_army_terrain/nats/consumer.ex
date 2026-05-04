defmodule BotArmyTerrain.NATS.Consumer do
  @moduledoc """
  NATS consumer for Terrain.

  Subscribes to:
  - bot.army.terrain.command.ingest — trigger ingestion (CSV, markdown, etc.)
  """

  use GenServer
  require Logger

  @reconnect_delay_ms 5000
  @version Mix.Project.config()[:version]
  @registry_heartbeat_ms 20_000

  @subjects [
    %{
      subject: "bot.army.terrain.command.ingest",
      type: :subscribe,
      description: "Ingest terrain data"
    },
    %{
      subject: "bot.army.terrain.command.import_cards",
      type: :subscribe,
      description: "Import cards"
    },
    %{
      subject: "bot.army.terrain.command.generate_cards",
      type: :subscribe,
      description: "Generate cards"
    },
    %{
      subject: "events.llm.response.parsed",
      type: :subscribe,
      description: "LLM response parsed"
    },
    %{
      subject: "events.llm.embedding.created",
      type: :subscribe,
      description: "LLM embedding created"
    },
    %{
      subject: "events.llm.completion.terrain.lesson_generation",
      type: :subscribe,
      description: "Lesson generation"
    },
    %{
      subject: "events.llm.completion.terrain.game_generation",
      type: :subscribe,
      description: "Game generation"
    }
  ]

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
      {:ok, conn} ->
        BotArmyRuntime.NATS.Connection.subscribe_to_status()
        subscribe(conn, state)

      {:error, _} ->
        schedule_reconnect(state)
    end
  end

  @impl true
  def handle_info({:msg, %{topic: topic, body: body} = msg}, state) do
    BotArmyRuntime.Tracing.with_consumer_span(topic, Map.get(msg, :headers, []), fn ->
      Logger.debug("Terrain received NATS: #{topic}")

      case decode(body) do
        {:ok, decoded} -> handle_command(topic, decoded)
        {:error, reason} -> Logger.warning("Terrain decode failed: #{inspect(reason)}")
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info(:connect_retry, state) do
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info({:nats, :disconnected}, state) do
    Logger.warning("Terrain disconnected from NATS, will reconnect")
    Process.send_after(self(), :connect_retry, @reconnect_delay_ms)
    {:noreply, %{state | subscriptions: []}}
  end

  @impl true
  def handle_info({:nats, :connected}, state) do
    Logger.info("Terrain reconnected to NATS, re-subscribing")
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info(:registry_heartbeat, state) do
    if state.subscriptions != [] do
      BotArmyRuntime.Registry.register("terrain", @subjects, @version)
      Process.send_after(self(), :registry_heartbeat, @registry_heartbeat_ms)
    end

    {:noreply, state}
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
    subjects = [
      "bot.army.terrain.command.ingest",
      "bot.army.terrain.command.import_cards",
      "bot.army.terrain.command.generate_cards",
      "events.llm.response.parsed",
      "events.llm.embedding.created",
      "events.llm.completion.terrain.lesson_generation",
      "events.llm.completion.terrain.game_generation"
    ]

    subs =
      Enum.map(subjects, fn subject ->
        case Gnat.sub(conn, self(), subject) do
          {:ok, sub} ->
            Logger.info("Terrain subscribed to #{subject}")
            sub

          {:error, reason} ->
            Logger.error("Terrain subscribe failed for #{subject}: #{inspect(reason)}")
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    if subs != [] do
      BotArmyRuntime.Registry.register("terrain", @subjects, @version)
      Process.send_after(self(), :registry_heartbeat, @registry_heartbeat_ms)
      {:noreply, %{state | subscriptions: subs}}
    else
      Logger.error("Terrain failed to subscribe to any subjects")
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

  defp handle_command("bot.army.terrain.command.import_cards", msg) do
    payload = msg["payload"] || msg
    path = payload["path"]

    case path do
      path when is_binary(path) and path != "" ->
        case BotArmyTerrain.Ingestion.CardImporter.import_csv(path) do
          {:ok, stats} -> Logger.info("Terrain card import completed: #{inspect(stats)}")
          {:error, reason} -> Logger.error("Terrain card import failed: #{inspect(reason)}")
        end

      _ ->
        Logger.info("Terrain card import: missing path")
    end
  end

  defp handle_command("bot.army.terrain.command.generate_cards", msg) do
    payload = msg["payload"] || msg
    path = payload["path"]
    text = payload["text"]
    track_name = payload["track_name"] || payload["track"] || "Default"
    model = payload["model"] || "haiku"

    result =
      cond do
        is_binary(path) and path != "" ->
          BotArmyTerrain.Ingestion.CardGenerator.generate_from_path(path,
            track_name: track_name,
            model: model
          )

        is_binary(text) and text != "" ->
          BotArmyTerrain.Ingestion.CardGenerator.generate_from_text(text,
            track_name: track_name,
            model: model
          )

        true ->
          {:error, :missing_path_or_text}
      end

    case result do
      {:ok, stats} -> Logger.info("Terrain card generation initiated: #{inspect(stats)}")
      {:error, reason} -> Logger.error("Terrain card generation failed: #{inspect(reason)}")
    end
  end

  defp handle_command("events.llm.response.parsed", msg) do
    case BotArmyTerrain.Handlers.LlmResponseHandler.handle_parsed(msg) do
      :ignore -> :ok
      _ -> :ok
    end
  end

  defp handle_command("events.llm.embedding.created", msg) do
    payload = msg["payload"] || %{}

    cond do
      payload["lesson_id"] ->
        BotArmyTerrain.Handlers.LessonEmbeddingHandler.handle_embedding(msg)

      payload["card_id"] ->
        BotArmyTerrain.Handlers.CardEmbeddingHandler.handle_embedding(msg)

      payload["chunk_id"] ->
        embedding = payload["embedding"]
        chunk_id = payload["chunk_id"]

        case BotArmyTerrain.ChunkStore.update_embedding(chunk_id, embedding) do
          {:ok, _chunk} ->
            Logger.debug("Updated embedding for chunk #{chunk_id}")

          {:error, reason} ->
            Logger.warning("Failed to update embedding for chunk #{chunk_id}: #{inspect(reason)}")
        end

      true ->
        Logger.warning("Unknown embedding type in payload")
    end

    :ok
  end

  defp handle_command("events.llm.completion.terrain.lesson_generation", msg) do
    BotArmyTerrain.Handlers.LessonCompletionHandler.handle_completion(msg)
    :ok
  end

  defp handle_command("events.llm.completion.terrain.game_generation", msg) do
    BotArmyTerrain.Handlers.GameCompletionHandler.handle_completion(msg)
    :ok
  end

  defp handle_command(_topic, _msg), do: :ok
end
