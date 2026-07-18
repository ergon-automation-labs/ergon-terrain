defmodule BotArmyTerrain.Handlers.SystemSignalHandler do
  @moduledoc """
  System-wide SM-2 SRS signal for retry confidence scoring.

  Queries aggregate card statistics (mean ease_factor, card count) and
  computes trend from recent session quality scores.
  """

  require Logger
  import Ecto.Query
  alias BotArmyTerrain.Repo
  alias BotArmyTerrain.Schemas.Card
  alias BotArmyTerrain.Schemas.ReviewSessionCard

  @min_ease_factor 1.3
  @max_ease_factor 3.5

  def handle_request(_msg) do
    case compute_signal() do
      {:ok, signal} ->
        BotArmyLibraryRuntime.NATS.Reply.ok(signal)

      {:error, reason} ->
        Logger.error("SystemSignalHandler failed: #{inspect(reason)}")
        BotArmyLibraryRuntime.NATS.Reply.error(inspect(reason), :signal_error)
    end
  end

  defp compute_signal do
    with {:ok, card_stats} <- fetch_card_stats(),
         {:ok, quality_trend} <- fetch_quality_trend(),
         {:ok, normalized} <- normalize_stats(card_stats, quality_trend) do
      {:ok, normalized}
    end
  end

  defp fetch_card_stats do
    case Repo.one(
           from(c in Card,
             where: c.state != "suspended",
             select: %{
               mean_ease: avg(c.ease_factor),
               card_count: count(c.id)
             }
           )
         ) do
      %{mean_ease: nil} ->
        {:ok, %{mean_ease: 2.5, card_count: 0}}

      %{mean_ease: mean, card_count: count} ->
        {:ok, %{mean_ease: mean, card_count: count}}

      nil ->
        {:ok, %{mean_ease: 2.5, card_count: 0}}

      error ->
        {:error, {:card_stats_failed, error}}
    end
  rescue
    e -> {:error, {:card_stats_exception, e}}
  end

  defp fetch_quality_trend do
    # Get last 3 sessions' average quality
    cutoff = DateTime.add(DateTime.utc_now(), -7, :day)

    case Repo.all(
           from(rsc in ReviewSessionCard,
             where: rsc.reviewed_at >= ^cutoff,
             group_by: fragment("DATE(?)", rsc.reviewed_at),
             select: %{
               date: fragment("DATE(?)", rsc.reviewed_at),
               avg_quality: avg(rsc.quality)
             },
             order_by: [desc: fragment("DATE(?)", rsc.reviewed_at)],
             limit: 3
           )
         ) do
      [] ->
        {:ok, :no_data}

      sessions ->
        qualities = Enum.map(sessions, & &1.avg_quality)
        {:ok, compute_trend(qualities)}
    end
  rescue
    e -> {:error, {:quality_trend_exception, e}}
  end

  defp compute_trend([a, b, c | _]) when is_number(a) and is_number(b) and is_number(c) do
    # Last 3 days' avg quality
    if a >= 3 and b >= 3 and c >= 3 do
      :improving
    else
      if a < 2 or b < 2 or c < 2 do
        :declining
      else
        :stable
      end
    end
  end

  defp compute_trend([a, b | _]) when is_number(a) and is_number(b) do
    if a >= 3 and b >= 3 do
      :improving
    else
      if a < 2 or b < 2 do
        :declining
      else
        :stable
      end
    end
  end

  defp compute_trend([_a | _]) do
    :stable
  end

  defp compute_trend(:no_data) do
    :stable
  end

  defp normalize_stats(%{mean_ease: mean_ease, card_count: card_count}, trend) do
    confidence = normalize_ease_factor(mean_ease)
    signal = if confidence < 0.4 or card_count < 10, do: "degraded", else: "nominal"

    {:ok,
     %{
       "confidence" => Float.round(confidence, 3),
       "mean_ease" => Float.round(mean_ease, 2),
       "card_count" => card_count,
       "trend" => Atom.to_string(trend),
       "signal" => signal
     }}
  end

  defp normalize_ease_factor(mean_ease) do
    # Normalize 1.3-3.5 range to 0-1
    normalized = (mean_ease - @min_ease_factor) / (@max_ease_factor - @min_ease_factor)
    # Clamp to 0-1
    max(0.0, min(1.0, normalized))
  end
end
