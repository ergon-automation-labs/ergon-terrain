defmodule BotArmyTerrain.PulsePublisher do
  @moduledoc """
  Publishes periodic health pulses from Terrain bot to Synapse.

  Terrain reports on learning operations:
  - Cards generated and their difficulty distribution
  - Active learners and engagement metrics
  - Study streak information
  - SRS (Spaced Repetition System) health

  This helps Synapse understand:
  - Whether learning content is being generated
  - Learner engagement and participation
  - Which domains have fresh content
  - System capacity for card generation

  Pulse format:
    {
      "bot": "terrain",
      "timestamp": "2026-04-25T10:25:00Z",
      "observations": {
        "cards_generated": N,
        "active_learners": N,
        "avg_card_difficulty": X.X,
        "domains_active": ["...", ...],
        "health_signal": "nominal|degraded|critical"
      }
    }
  """

  use GenServer
  require Logger

  @health_interval_ms 30 * 1000
  # 5 minutes
  @publish_interval_ms 30 * 60 * 1000
  @server __MODULE__

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: @server)
  end

  @impl true
  def init(_opts) do
    Logger.info("[PulsePublisher] Starting Terrain pulse publisher")

    state = %{
      cards_generated: 0,
      total_difficulty: 0.0,
      active_learners: MapSet.new(),
      domains_active: MapSet.new()
    }

    Process.send_after(self(), :publish_pulse, @publish_interval_ms)
    Process.send_after(self(), :publish_health, 2_000)
    {:ok, state}
  end

  @impl true
  def handle_info(:publish_health, state) do
    health_signal =
      cond do
        state.cards_generated == 0 -> "degraded"
        MapSet.size(state.active_learners) == 0 -> "degraded"
        true -> "nominal"
      end

    BotArmyLibraryRuntime.SynapseHealth.publish(
      source: "bot_army_terrain",
      service: "terrain",
      health_signal: health_signal
    )

    Process.send_after(self(), :publish_health, @health_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(:publish_pulse, state) do
    Task.start(fn -> publish_pulse(state) end)
    Process.send_after(self(), :publish_pulse, @publish_interval_ms)

    # Reset counters for next period
    new_state = %{
      state
      | cards_generated: 0,
        total_difficulty: 0.0,
        active_learners: MapSet.new(),
        domains_active: MapSet.new()
    }

    {:noreply, new_state}
  end

  @impl true
  def handle_call({:record_card_generated, difficulty, domain}, _from, state) do
    new_state = %{
      state
      | cards_generated: state.cards_generated + 1,
        total_difficulty: state.total_difficulty + difficulty,
        domains_active: MapSet.put(state.domains_active, domain)
    }

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:record_learner_active, learner_id}, _from, state) do
    new_state = %{state | active_learners: MapSet.put(state.active_learners, learner_id)}
    {:reply, :ok, new_state}
  end

  # API for other modules
  def record_card_generated(difficulty, domain) when is_float(difficulty) and is_binary(domain) do
    try do
      GenServer.call(@server, {:record_card_generated, difficulty, domain})
    catch
      :exit, _ -> :ok
    end
  end

  def record_learner_active(learner_id) when is_binary(learner_id) do
    try do
      GenServer.call(@server, {:record_learner_active, learner_id})
    catch
      :exit, _ -> :ok
    end
  end

  # Private

  defp publish_pulse(state) do
    pulse = build_pulse(state)
    publish_to_nats(pulse)
    maybe_publish_tavern_gossip(state)
  end

  defp maybe_publish_tavern_gossip(state) do
    text =
      cond do
        state.cards_generated >= 10 ->
          "📜 #{state.cards_generated} cards forged today. The dojo hums with knowledge."

        state.cards_generated > 0 ->
          "📜 #{state.cards_generated} card#{if(state.cards_generated > 1, do: "s", else: "")} forged. Slow but steady."

        MapSet.size(state.active_learners) > 0 ->
          "🎯 #{MapSet.size(state.active_learners)} learner#{if(MapSet.size(state.active_learners) > 1, do: "s", else: "")} active. Waiting for new material."

        true ->
          nil
      end

    if text do
      gossip = %{
        "event" => "gossip.tavern.narrated",
        "source" => "terrain_bot",
        "text" => text,
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      case GenServer.call(BotArmyLibraryRuntime.NATS.Connection, :get_connection, 5_000) do
        {:ok, conn} ->
          case Gnat.pub(conn, "gossip.tavern.narrated", Jason.encode!(gossip)) do
            :ok ->
              Logger.info("[PulsePublisher] Published tavern gossip")

            {:error, reason} ->
              Logger.warning("[PulsePublisher] Gossip failed: #{inspect(reason)}")
          end

        {:error, reason} ->
          Logger.warning("[PulsePublisher] NATS unavailable for gossip: #{inspect(reason)}")
      end
    end
  end

  defp build_pulse(state) do
    avg_difficulty =
      if state.cards_generated > 0,
        do: state.total_difficulty / state.cards_generated,
        else: 0.0

    health_signal =
      cond do
        state.cards_generated == 0 -> "degraded"
        MapSet.size(state.active_learners) == 0 -> "degraded"
        true -> "nominal"
      end

    %{
      "bot" => "terrain",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "observations" => %{
        "cards_generated" => state.cards_generated,
        "active_learners" => MapSet.size(state.active_learners),
        "avg_card_difficulty" => Float.round(avg_difficulty, 2),
        "domains_active" => MapSet.to_list(state.domains_active),
        "health_signal" => health_signal
      }
    }
  end

  defp publish_to_nats(pulse) do
    try do
      case GenServer.call(BotArmyLibraryRuntime.NATS.Connection, :get_connection, 5_000) do
        {:ok, conn} ->
          json = Jason.encode!(pulse)

          case Gnat.pub(conn, "bot.terrain.pulse", json) do
            :ok ->
              Logger.debug("[PulsePublisher] Published Terrain pulse")

            {:error, reason} ->
              Logger.warning("[PulsePublisher] Failed to publish pulse: #{inspect(reason)}")
          end

        {:error, reason} ->
          Logger.warning("[PulsePublisher] NATS unavailable, skipping pulse: #{inspect(reason)}")
      end
    rescue
      e ->
        Logger.warning("[PulsePublisher] Error publishing pulse: #{inspect(e)}")
    end
  end
end
