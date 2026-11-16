defmodule BotArmyTerrain.Pitch do
  @moduledoc """
  One purpose spot for one GTD project: the why she wrote, and one five-minute door.

  The story's interstitials sell a lesson. These sell a reason. Selection is
  deliberately **not** due-ness: the most overdue project is exactly the one the
  ADHD lens says not to put on a card. A project is eligible because its next
  action is small and doable now, not because it is late.

  A project with no why is not skipped — it is asked for one. That question is
  the pitch meeting, and the sentence it produces is the spot.
  """

  @reuse_days 7
  @snooze_days 7
  @why_max 280
  @kicker "WHY THIS MATTERS"

  @type project :: map()
  @type state :: map() | nil

  @doc """
  The project to draw, or `nil` when nothing is worth putting on a card today.

  `projects` are the GTD rows the panel already holds. `states` are this tenant's
  pitch rows keyed by `project_id`. A ready spot wins over an ask so a project
  that can already air is not held back by one that needs a sentence.
  """
  @spec pick([project()], %{optional(String.t()) => state()}, DateTime.t()) :: map() | nil
  def pick(projects, states, now \\ DateTime.utc_now())

  def pick(projects, states, %DateTime{} = now),
    do: pick(projects, states, now, DateTime.to_date(now))

  @spec pick([project()], %{optional(String.t()) => state()}, DateTime.t(), Date.t()) ::
          map() | nil
  def pick(projects, states, now, today)

  def pick(projects, states, %DateTime{} = now, %Date{} = today)
      when is_list(projects) and is_map(states) do
    candidates =
      projects
      |> Enum.map(&candidate/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&(&1.status in ["completed", "archived", "retired"]))
      |> Enum.map(&Map.put(&1, :state, Map.get(states, &1.id)))

    ready =
      candidates
      |> Enum.filter(&(why(&1) not in [nil, ""]))
      |> Enum.filter(&servable?(&1, now, today))

    asks =
      candidates
      |> Enum.filter(&(why(&1) in [nil, ""]))
      |> Enum.filter(&askable?(&1, now, today))

    cond do
      ready != [] ->
        ready
        |> Enum.min_by(&{-spot_score(&1, now), &1.id})
        |> spot()

      asks != [] ->
        asks
        |> Enum.min_by(&{-ask_score(&1, now), &1.id})
        |> ask()

      true ->
        nil
    end
  end

  def pick(_projects, _states, _now, _today), do: nil

  @doc """
  Trim and bound her sentence. Blank is not a why; too long is not a sentence.

  There is no shame filter on her own words: quoting "the taxes I have been
  avoiding" is not the system shaming her, it is her own description of the
  project. The ad's framing is where the rule lives.
  """
  @spec clean_why(term()) :: {:ok, String.t()} | {:error, :blank_why | :why_too_long}
  def clean_why(text) when is_binary(text) do
    case String.trim(text) do
      "" -> {:error, :blank_why}
      why when byte_size(why) > @why_max -> {:error, :why_too_long}
      why -> {:ok, why}
    end
  end

  def clean_why(_text), do: {:error, :blank_why}

  @doc "When a snooze ends. A date, never a judgement."
  @spec snooze_until(DateTime.t()) :: DateTime.t()
  def snooze_until(now \\ DateTime.utc_now()),
    do: DateTime.add(now, @snooze_days * 86_400, :second)

  # ── candidates ────────────────────────────────────────────────────────────────────────────

  defp candidate(%{"id" => id, "name" => name} = project)
       when is_binary(id) and id != "" and is_binary(name) and name != "" do
    %{
      id: id,
      name: String.trim(name),
      why: text(project["why"]) || metadata(project, "why"),
      next_action: text(project["next_action"]) || metadata(project, "next_action"),
      area: text(project["area"]),
      status: text(project["status"]) || "active"
    }
  end

  defp candidate(_project), do: nil

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp text(_value), do: nil

  defp metadata(%{"metadata" => %{} = metadata}, key), do: text(metadata[key])
  defp metadata(_project, _key), do: nil

  # ── eligibility ───────────────────────────────────────────────────────────────────────────

  defp servable?(project, now, today) do
    not blank?(project.next_action) and
      not retired?(project.state) and
      not snoozed?(project.state, now) and
      not shown_today?(project.state, today) and
      not shown_recently?(project.state, now)
  end

  defp askable?(project, now, today) do
    not blank?(project.next_action) and
      not retired?(project.state) and
      not snoozed?(project.state, now) and
      not shown_today?(project.state, today) and
      not shown_recently?(project.state, now)
  end

  defp blank?(value), do: value in [nil, ""]

  defp retired?(nil), do: false

  defp retired?(state),
    do: state[:status] == "retired" or not is_nil(state[:retired_at])

  defp snoozed?(nil, _now), do: false

  defp snoozed?(state, now) do
    case state[:snoozed_until] do
      %DateTime{} = until -> DateTime.compare(until, now) == :gt
      _ -> false
    end
  end

  defp shown_today?(nil, _today), do: false
  defp shown_today?(state, today), do: state[:last_shown_on] == today

  defp shown_recently?(nil, _now), do: false

  defp shown_recently?(state, now) do
    case state[:last_shown_at] do
      %DateTime{} = at -> DateTime.compare(at, cutoff(now)) == :gt
      _ -> false
    end
  end

  defp cutoff(now), do: DateTime.add(now, -@reuse_days * 86_400, :second)

  # ── scoring ───────────────────────────────────────────────────────────────────────────────

  defp spot_score(project, now) do
    state = project.state
    never = is_nil(state) or is_nil(state[:last_shown_at])
    authored = not is_nil(state) and is_binary(state[:why]) and state[:why] != ""

    if(never, do: 4.0, else: 0.0) +
      gap_days(state, now) * 0.2 +
      if(authored, do: 1.0, else: 0.0) +
      if is_binary(project.area), do: 0.5, else: 0.0
  end

  defp ask_score(project, now) do
    state = project.state
    never = is_nil(state) or is_nil(state[:last_shown_at])

    if(never, do: 5.0, else: 0.0) +
      gap_days(state, now) * 0.1 +
      if is_binary(project.area), do: 0.5, else: 0.0
  end

  defp gap_days(nil, _now), do: 0

  defp gap_days(state, now) do
    case state[:last_shown_at] do
      %DateTime{} = at -> max(DateTime.diff(now, at, :day), 0)
      _ -> 0
    end
  end

  # ── cards ─────────────────────────────────────────────────────────────────────────────────

  defp spot(project) do
    %{
      "kind" => "spot",
      "project_id" => project.id,
      "name" => project.name,
      "kicker" => @kicker,
      "why" => why(project),
      "next_action" => project.next_action,
      "line" => "The next five minutes: #{project.next_action}.",
      "actions" => ["start", "snooze", "retire"]
    }
  end

  defp ask(project) do
    %{
      "kind" => "ask_why",
      "project_id" => project.id,
      "name" => project.name,
      "question" => "Why does #{project.name} matter to you?",
      "hint" => "One sentence, in your own words. It becomes the next spot.",
      "next_action" => project.next_action
    }
  end

  defp why(%{state: state, why: project_why}) do
    case state && state[:why] do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> project_why
          trimmed -> trimmed
        end

      _ ->
        project_why
    end
  end
end
