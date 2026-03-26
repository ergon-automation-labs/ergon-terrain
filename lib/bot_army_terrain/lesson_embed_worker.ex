defmodule BotArmyTerrain.LessonEmbedWorker do
  @moduledoc """
  Background worker for embedding lessons via LLM.

  Mirrors EmbedWorker pattern but for lessons: queues lessons for vectorization,
  publishes embed requests, receives embeddings, and updates lessons with vectors.
  """

  use GenServer
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_) do
    {:ok, %{}}
  end

  @doc "Queue a lesson for background embedding."
  def queue_lesson(lesson_id) do
    GenServer.cast(__MODULE__, {:embed_lesson, lesson_id})
  end

  @impl true
  def handle_cast({:embed_lesson, lesson_id}, state) do
    lesson = BotArmyTerrain.Repo.get(BotArmyTerrain.Schemas.Lesson, lesson_id)

    if lesson do
      text = "#{lesson.title} #{lesson.explanation}"

      payload = %{
        "event" => "llm.embed.request",
        "event_id" => UUID.uuid4() |> to_string(),
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "source" => "bot_army_terrain",
        "source_node" => get_node_name(),
        "triggered_by" => "lesson_embed_worker",
        "schema_version" => "1.0",
        "payload" => %{
          "text" => text,
          "lesson_id" => to_string(lesson.id),
          "model" => "nomic-embed-text"
        }
      }

      case get_connection() do
        {:ok, conn} ->
          case Gnat.pub(conn, "llm.embed.request", Jason.encode!(payload)) do
            :ok ->
              Logger.debug("Queued lesson embedding: #{lesson_id}")

            {:error, reason} ->
              Logger.error("Failed to queue lesson embedding: #{inspect(reason)}")
          end

        {:error, _} ->
          Logger.warning("NATS unavailable, lesson embed deferred: #{lesson_id}")
      end
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

  defp get_node_name do
    case :inet.gethostname() do
      {:ok, hostname} -> to_string(hostname)
      {:error, _} -> "unknown"
    end
  end
end
