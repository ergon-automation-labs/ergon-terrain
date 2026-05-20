defmodule BotArmyTerrain.Skills.SystemChallengeBuild do
  @moduledoc """
  Daily **system literacy** challenge: persist a lesson row from internal-docs excerpts
  (separate from user-imported tracks) and publish `bot.army.terrain.event.system_challenge_ready`.

  Idempotent on `(tenant_id, challenge_date, challenge_slug)` via deterministic `chunk_id` (UUID v5).

  Trigger: `bot.army.terrain.command.system_challenge_build`
  """

  use BotArmy.Skill
  require Logger

  alias BotArmyTerrain.Schemas.Lesson

  @max_explanation_bytes 100_000

  @impl true
  def name, do: :system_challenge_build

  @impl true
  def description do
    "Build idempotent system-literacy Terrain lesson from internal-docs excerpts; emit system_challenge_ready"
  end

  @impl true
  def nats_triggers do
    ["bot.army.terrain.command.system_challenge_build"]
  end

  @impl true
  def llm_hint, do: :none

  @impl true
  def validate(input) when is_map(input) do
    payload = input["payload"] || input

    with {:ok, _} <- cast_uuid(payload["tenant_id"]),
         :ok <- validate_excerpts(payload) do
      :ok
    else
      {:error, msg} -> {:error, msg}
    end
  end

  def validate(_), do: {:error, "input must be a map"}

  defp validate_excerpts(payload) do
    excerpts = payload["internal_docs_excerpts"]
    smoke = truthy?(payload["smoke"])

    cond do
      smoke ->
        :ok

      is_binary(excerpts) and String.trim(excerpts) != "" ->
        :ok

      true ->
        {:error, "internal_docs_excerpts required (non-empty), or pass smoke: true for dry runs"}
    end
  end

  @impl true
  def execute(input, _ctx) do
    payload = input["payload"] || input

    with {:ok, tenant_id} <- cast_uuid(payload["tenant_id"]),
         {:ok, user_id} <- optional_uuid(payload["user_id"]),
         {:ok, challenge_date} <- challenge_date(payload),
         slug = payload["challenge_slug"] || "system-daily",
         chunk_id = deterministic_chunk_id(tenant_id, challenge_date, slug) do
      persist_and_publish(payload, tenant_id, user_id, challenge_date, slug, chunk_id)
    end
  end

  defp persist_and_publish(payload, tenant_id, user_id, challenge_date, slug, chunk_id) do
    smoke = truthy?(payload["smoke"])

    excerpts =
      if smoke do
        payload["internal_docs_excerpts"] ||
          "# Smoke\n\nNo excerpts supplied; placeholder system challenge body."
      else
        payload["internal_docs_excerpts"]
      end

    explanation = excerpts |> to_string() |> String.slice(0, @max_explanation_bytes)
    title = payload["title"] || "System literacy · #{slug} · #{challenge_date}"
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attrs = %{
      "chunk_id" => chunk_id,
      "track_id" => nil,
      "title" => title,
      "explanation" => explanation,
      "external_link" => "",
      "difficulty" => 1,
      "generated_at" => now,
      "user_id" => user_id
    }

    case BotArmyTerrain.LessonStore.get_lesson_by_chunk(tenant_id, chunk_id) do
      %Lesson{} = lesson ->
        {:ok,
         base_result("already_built", tenant_id, challenge_date, slug, chunk_id, lesson.title)
         |> Map.put("published_event", false)}

      nil ->
        case BotArmyTerrain.LessonStore.store_lesson(tenant_id, attrs) do
          {:ok, lesson} ->
            publish_ready_event!(tenant_id, challenge_date, slug, chunk_id, lesson.title, true)
            {:ok, base_result("created", tenant_id, challenge_date, slug, chunk_id, lesson.title)}

          {:error, changeset} ->
            Logger.error(
              "[SystemChallengeBuild] store_lesson failed: #{inspect(changeset.errors)}"
            )

            {:error, :persist_failed}
        end
    end
  end

  defp base_result(status, tenant_id, challenge_date, slug, chunk_id, title) do
    %{
      "status" => status,
      "tenant_id" => tenant_id,
      "challenge_date" => challenge_date,
      "challenge_slug" => slug,
      "challenge_id" => chunk_id,
      "chunk_id" => chunk_id,
      "source" => "system_challenge",
      "title" => title,
      "published_event" => true
    }
  end

  defp challenge_date(payload) do
    case payload["challenge_date"] do
      d when is_binary(d) ->
        trimmed = String.trim(d)
        if trimmed != "", do: {:ok, trimmed}, else: default_challenge_date()

      _ ->
        default_challenge_date()
    end
  end

  defp default_challenge_date, do: {:ok, Date.utc_today() |> Date.to_iso8601()}

  defp deterministic_chunk_id(tenant_id, challenge_date, slug) do
    seed = "terrain.system_challenge|#{tenant_id}|#{challenge_date}|#{slug}"
    UUID.uuid5(:dns, seed)
  end

  defp cast_uuid(nil), do: {:error, "tenant_id required (UUID)"}

  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(String.trim(value)) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, "tenant_id must be a UUID"}
    end
  end

  defp cast_uuid(_), do: {:error, "tenant_id must be a string UUID"}

  defp optional_uuid(nil), do: {:ok, nil}

  defp optional_uuid(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      {:ok, nil}
    else
      case Ecto.UUID.cast(trimmed) do
        {:ok, uuid} -> {:ok, uuid}
        :error -> {:error, "user_id must be a UUID when set"}
      end
    end
  end

  defp optional_uuid(_), do: {:error, "user_id must be a string UUID or empty"}

  defp truthy?(v) when v in [true, "true", "1", 1], do: true
  defp truthy?(_), do: false

  defp publish_ready_event!(tenant_id, challenge_date, slug, chunk_id, title, created) do
    envelope = %{
      "schema_version" => "1.0",
      "event" => "bot.army.terrain.event.system_challenge_ready",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "payload" => %{
        "tenant_id" => tenant_id,
        "challenge_date" => challenge_date,
        "challenge_slug" => slug,
        "challenge_id" => chunk_id,
        "chunk_id" => chunk_id,
        "source" => "system_challenge",
        "title" => title,
        "created" => created
      }
    }

    try do
      case GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 5_000) do
        {:ok, conn} ->
          case Gnat.pub(
                 conn,
                 "bot.army.terrain.event.system_challenge_ready",
                 Jason.encode!(envelope)
               ) do
            :ok ->
              Logger.info(
                "[SystemChallengeBuild] Published system_challenge_ready chunk_id=#{chunk_id}"
              )

            {:error, reason} ->
              Logger.warning(
                "[SystemChallengeBuild] NATS publish system_challenge_ready failed: #{inspect(reason)}"
              )
          end

        {:error, reason} ->
          Logger.warning("[SystemChallengeBuild] NATS unavailable: #{inspect(reason)}")
      end
    rescue
      e ->
        Logger.warning("[SystemChallengeBuild] publish exception: #{inspect(e)}")
    end
  end
end
