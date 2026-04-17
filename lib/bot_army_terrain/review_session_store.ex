defmodule BotArmyTerrain.ReviewSessionStore do
  @moduledoc """
  Review session management: create, end, record card reviews, and compute stats.
  """

  use GenServer
  require Logger
  import Ecto.Query

  alias BotArmyTerrain.Repo
  alias BotArmyTerrain.Schemas.ReviewSession
  alias BotArmyTerrain.Schemas.ReviewSessionCard

  @behaviour BotArmyTerrain.ReviewSessionStoreBehaviour

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Create a new review session for a track, scoped to tenant."
  def create_session(tenant_id, attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    %ReviewSession{}
    |> ReviewSession.changeset(%{
      tenant_id: tenant_id,
      track_id: attrs["track_id"],
      started_at: DateTime.utc_now(),
      state: "active"
    })
    |> Repo.insert()
  end

  @doc "End a review session, marking it complete with ended_at timestamp, scoped to tenant."
  def end_session(tenant_id, session_id) do
    case Repo.get(ReviewSession, session_id) do
      nil ->
        {:error, :not_found}

      session ->
        if session.tenant_id == tenant_id do
          session
          |> ReviewSession.changeset(%{
            state: "complete",
            ended_at: DateTime.utc_now()
          })
          |> Repo.update()
        else
          {:error, :unauthorized}
        end
    end
  end

  @doc "Record a card review and update session counters, scoped to tenant."
  def record_card_review(tenant_id, user_id, attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    with {:ok, session_id} <- extract_session_id(attrs),
         {:ok, _session} <- verify_session_tenant(session_id, tenant_id),
         {:ok, quality} <- extract_quality(attrs) do
      case Repo.transaction(fn ->
             with {:ok, _card_review} <- insert_card_review(tenant_id, attrs),
                  :ok <- update_session_counters!(session_id, quality) do
               :ok
             else
               {:error, reason} -> Repo.rollback(reason)
             end
           end) do
        {:ok, :ok} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Get session statistics by session ID, scoped to tenant."
  def get_session_stats(tenant_id, session_id) do
    case Repo.get(ReviewSession, session_id) do
      nil ->
        {:error, :not_found}

      session ->
        if session.tenant_id == tenant_id do
          duration_ms = compute_duration_ms(session)
          accuracy = compute_accuracy(session.cards_reviewed, session.cards_correct)

          {:ok,
           %{
             cards_reviewed: session.cards_reviewed,
             cards_correct: session.cards_correct,
             accuracy: accuracy,
             duration_ms: duration_ms,
             state: session.state
           }}
        else
          {:error, :unauthorized}
        end
    end
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  # Private helpers

  defp extract_session_id(attrs) do
    case attrs["session_id"] do
      nil -> {:error, :missing_session_id}
      id when is_binary(id) -> {:ok, id}
      _ -> {:error, :invalid_session_id}
    end
  end

  defp extract_quality(attrs) do
    case attrs["quality"] do
      nil ->
        {:error, :missing_quality}

      quality when is_integer(quality) and quality >= 0 and quality <= 5 ->
        {:ok, quality}

      quality when is_float(quality) and quality >= 0.0 and quality <= 5.0 ->
        {:ok, trunc(quality)}

      _ ->
        {:error, :invalid_quality}
    end
  end

  defp verify_session_tenant(session_id, tenant_id) do
    case Repo.get(ReviewSession, session_id) do
      nil ->
        {:error, :not_found}

      session ->
        if session.tenant_id == tenant_id, do: {:ok, session}, else: {:error, :unauthorized}
    end
  end

  defp insert_card_review(tenant_id, attrs) do
    %ReviewSessionCard{}
    |> ReviewSessionCard.changeset(%{
      tenant_id: tenant_id,
      session_id: attrs["session_id"],
      card_id: attrs["card_id"],
      quality: attrs["quality"],
      elapsed_ms: attrs["elapsed_ms"] || 0,
      reviewed_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end

  defp update_session_counters(session_id, quality) do
    case Repo.get(ReviewSession, session_id) do
      nil ->
        Logger.warning("Session #{session_id} not found for counter update")
        :ok

      session ->
        cards_correct_increment = if quality >= 3, do: 1, else: 0

        updated_session =
          session
          |> ReviewSession.changeset(%{
            cards_reviewed: session.cards_reviewed + 1,
            cards_correct: session.cards_correct + cards_correct_increment
          })
          |> Repo.update!()

        Logger.debug(
          "Session #{session_id}: reviewed=#{updated_session.cards_reviewed} correct=#{updated_session.cards_correct}"
        )

        :ok
    end
  end

  # Transaction-safe variant: returns error instead of raising, for use inside Repo.transaction
  defp update_session_counters!(session_id, quality) do
    case Repo.get(ReviewSession, session_id) do
      nil ->
        {:error, :session_not_found}

      session ->
        cards_correct_increment = if quality >= 3, do: 1, else: 0

        case session
             |> ReviewSession.changeset(%{
               cards_reviewed: session.cards_reviewed + 1,
               cards_correct: session.cards_correct + cards_correct_increment
             })
             |> Repo.update() do
          {:ok, updated_session} ->
            Logger.debug(
              "Session #{session_id}: reviewed=#{updated_session.cards_reviewed} correct=#{updated_session.cards_correct}"
            )

            :ok

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp compute_duration_ms(session) do
    case {session.started_at, session.ended_at} do
      {start, end_time} when is_struct(start, DateTime) and is_struct(end_time, DateTime) ->
        DateTime.diff(end_time, start, :millisecond)

      {start, nil} when is_struct(start, DateTime) ->
        DateTime.diff(DateTime.utc_now(), start, :millisecond)

      _ ->
        0
    end
  end

  defp compute_accuracy(0, _correct), do: 0.0

  defp compute_accuracy(reviewed, correct) do
    (correct / reviewed * 100.0) |> Float.round(1)
  end
end
