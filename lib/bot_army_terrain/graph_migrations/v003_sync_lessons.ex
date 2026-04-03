defmodule BotArmyTerrain.GraphMigrations.V003SyncLessons do
  @moduledoc """
  Migration V003: Sync Lesson nodes from relational DB to graph.

  Reads all lessons from BotArmyTerrain.Repo and upserts them as
  Lesson nodes in the knowledge graph.
  """

  require Logger

  @version 3
  @description "Sync Lesson nodes from relational database"

  def version, do: @version
  def description, do: @description

  def up do
    Logger.info("[Migration V003] Syncing lessons to graph...")

    lessons = fetch_all_lessons()
    Logger.info("[Migration V003] Found #{Enum.count(lessons)} lessons")

    upsert_lesson_nodes(lessons)

    Logger.info("[Migration V003] Synced #{Enum.count(lessons)} lesson nodes to graph")
    :ok
  end

  defp fetch_all_lessons do
    BotArmyTerrain.Repo.all(BotArmyTerrain.Lesson)
  rescue
    e ->
      Logger.error("[Migration V003] Failed to fetch lessons", error: inspect(e))
      []
  end

  defp upsert_lesson_nodes(lessons) do
    nodes =
      Enum.map(lessons, fn lesson ->
        %{
          id: UUID.binary_to_string!(lesson.id),
          type: "Lesson",
          name: lesson.title,
          properties: %{
            title: lesson.title,
            difficulty: lesson.difficulty,
            track_id:
              if(lesson.track_id, do: UUID.binary_to_string!(lesson.track_id), else: nil),
            external_link: lesson.external_link,
            generated_at: lesson.generated_at
          }
        }
      end)

    case BotArmy.Graph.upsert_nodes(nodes) do
      {:ok, count} ->
        Logger.info("[Migration V003] Upserted #{count} lesson nodes")
        :ok

      {:error, e} ->
        Logger.error("[Migration V003] Failed to upsert lesson nodes", error: inspect(e))
        raise "Could not upsert lesson nodes: #{inspect(e)}"
    end
  end
end
