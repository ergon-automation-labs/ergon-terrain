defmodule BotArmyTerrain.SM2 do
  @moduledoc """
  SM-2 spaced repetition scheduling algorithm.

  Given a card and a quality rating (0-5), computes the next review interval
  and updates the ease factor according to SM-2 rules.

  Quality scale:
  - 0: Complete blackout, incorrect response
  - 1: Blackout, serious difficulty
  - 2: Serious difficulty
  - 3: Difficult, but correct response
  - 4: Correct response after some hesitation
  - 5: Perfect response

  Returns a map with updated SRS fields suitable for `Card.changeset/2`.
  """

  @min_ease_factor 1.3

  @doc """
  Schedule a card for the next review based on quality rating.

  Args:
    - card: A Card struct or map with ease_factor, interval_days, repetitions
    - quality: Integer 0-5

  Returns:
    %{
      ease_factor: float,
      interval_days: integer,
      repetitions: integer,
      state: string,
      next_review_at: DateTime,
      last_reviewed_at: DateTime
    }
  """
  def schedule(card, quality) when quality in 0..5 do
    now = DateTime.utc_now()
    ease_factor = get_field(card, :ease_factor, 2.5)
    repetitions = get_field(card, :repetitions, 0)

    prev_interval = get_field(card, :interval_days, 1)

    {new_repetitions, new_interval_days, new_ease_factor} =
      if quality < 3 do
        # Failed: reset repetitions and interval
        new_ef = max(@min_ease_factor, ease_factor + 0.1 - (5 - quality) * (0.08 + (5 - quality) * 0.02))
        {0, 1, new_ef}
      else
        # Passed: increment repetitions and compute interval
        new_rep = repetitions + 1
        new_interval = compute_interval(new_rep, prev_interval, ease_factor)
        new_ef = max(@min_ease_factor, ease_factor + 0.1 - (5 - quality) * (0.08 + (5 - quality) * 0.02))
        {new_rep, new_interval, new_ef}
      end

    state = compute_state(new_repetitions)
    next_review = add_days(now, new_interval_days)

    %{
      ease_factor: new_ease_factor,
      interval_days: new_interval_days,
      repetitions: new_repetitions,
      state: state,
      next_review_at: next_review,
      last_reviewed_at: now
    }
  end

  defp compute_interval(repetitions, _prev_interval, _ease_factor) when repetitions == 1 do
    1
  end

  defp compute_interval(repetitions, _prev_interval, _ease_factor) when repetitions == 2 do
    3
  end

  defp compute_interval(_repetitions, prev_interval, ease_factor) do
    (prev_interval * ease_factor) |> Float.round() |> trunc()
  end

  defp compute_state(repetitions) when repetitions == 0, do: "learning"
  defp compute_state(repetitions) when repetitions < 3, do: "learning"
  defp compute_state(_repetitions), do: "review"

  defp add_days(datetime, days) do
    datetime
    |> DateTime.add(days * 24 * 3600, :second)
  end

  defp get_field(card, key, default) do
    case card do
      %{^key => value} when not is_nil(value) -> value
      _ -> default
    end
  end
end
