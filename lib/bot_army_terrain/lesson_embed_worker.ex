defmodule BotArmyTerrain.LessonEmbedWorker do
  @moduledoc """
  Background worker for embedding lessons via LLM.

  Mirrors EmbedWorker pattern but for lessons: queues lessons for vectorization,
  publishes embed requests to llm.embed.request, receives embeddings via handler,
  and updates lessons with vector embeddings.

  Fire-and-forget pattern: cast → publish → return immediately.
  Failures are logged but don't block or retry.
  """

  use GenServer
  require Logger

  alias BotArmyTerrain.Repo
  alias BotArmyTerrain.Schemas.Lesson

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @doc """
  Queue a lesson for background embedding (fire-and-forget).

  Fetches lesson by ID, publishes embedding request with title+explanation text,
  receives embeddings asynchronously via LessonEmbeddingHandler.
  """
  def queue_lesson(tenant_id, lesson_id) do
    GenServer.cast(__MODULE__, {:embed_lesson, tenant_id, lesson_id})
  end

  @impl true
  def handle_cast({:embed_lesson, tenant_id, lesson_id}, state) do
    case Repo.get(Lesson, lesson_id) do
      nil ->
        Logger.warning("Lesson #{lesson_id} not found for embedding")
        {:noreply, state}

      lesson ->
        case publish_embed_request(lesson) do
          :ok ->
            Logger.debug("Queued embedding for lesson #{lesson_id}")
            {:noreply, state}

          {:error, reason} ->
            Logger.warning("Failed to queue embedding for lesson #{lesson_id}: #{inspect(reason)}")
            {:noreply, state}
        end
    end
  end

  # Private helpers

  defp publish_embed_request(lesson) do
    case get_connection() do
      {:ok, conn} ->
        subject = "llm.embed.request"
        text = "#{lesson.title} #{lesson.explanation}"

        payload = %{
          "text" => text,
          "lesson_id" => lesson.id,
          "model" => "nomic-embed-text"
        }

        event = %{
          "event" => "llm.embed.request",
          "event_id" => Ecto.UUID.generate(),
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "source" => "bot_army_terrain",
          "source_node" => node() |> Atom.to_string(),
          "triggered_by" => "lesson_embed_worker",
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
      GenServer.call(BotArmyLibraryRuntime.NATS.Connection, :get_connection, 5000)
    rescue
      _ -> {:error, :unavailable}
    catch
      :exit, _ -> {:error, :unavailable}
    end
  end
end
