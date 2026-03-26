defmodule BotArmyTerrain.Handlers.LessonEmbeddingHandler do
  @moduledoc """
  Handler for lesson embedding updates from LLM service.

  Listens on events.llm.embedding.created for lesson_id payloads,
  updates the lesson with its embedding vector.
  """

  require Logger
  alias BotArmyTerrain.{LessonStore, Repo, Schemas.Lesson}

  def handle_embedding(message) do
    payload = message["payload"] || %{}
    lesson_id = payload["lesson_id"]
    embedding = payload["embedding"]

    if lesson_id && embedding do
      case Repo.get(Lesson, lesson_id) do
        nil ->
          Logger.warning("LessonEmbeddingHandler: lesson not found #{lesson_id}")

        lesson ->
          vector = Pgvector.new(embedding)

          case LessonStore.update_lesson(lesson, %{
                 embedding_vector: vector,
                 embedded_at: DateTime.utc_now()
               }) do
            {:ok, _} ->
              Logger.debug("Lesson #{lesson_id} embedding updated")

            {:error, reason} ->
              Logger.error("Failed to update lesson embedding: #{inspect(reason)}")
          end
      end
    end
  end
end
