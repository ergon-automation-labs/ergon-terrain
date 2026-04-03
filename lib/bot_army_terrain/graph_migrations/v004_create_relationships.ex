defmodule BotArmyTerrain.GraphMigrations.V004CreateRelationships do
  @moduledoc """
  Migration V004: Create BELONGS_TO edges between Lessons and Tracks.

  For each lesson that has a track_id, creates a BELONGS_TO relationship
  to its parent track in the graph.
  """

  require Logger
  import Ecto.Query

  @version 4
  @description "Create BELONGS_TO relationships between lessons and tracks"

  def version, do: @version
  def description, do: @description

  def up do
    Logger.info("[Migration V004] Creating lesson-to-track relationships...")

    lessons = fetch_lessons_with_tracks()
    Logger.info("[Migration V004] Found #{Enum.count(lessons)} lessons with tracks")

    create_belongs_to_edges(lessons)

    Logger.info("[Migration V004] Created lesson-to-track relationships")
    :ok
  end

  defp fetch_lessons_with_tracks do
    BotArmyTerrain.Repo.all(
      from l in BotArmyTerrain.Lesson,
        where: not is_nil(l.track_id),
        select: %{
          lesson_id: l.id,
          track_id: l.track_id
        }
    )
  rescue
    e ->
      Logger.error("[Migration V004] Failed to fetch lessons", error: inspect(e))
      []
  end

  defp create_belongs_to_edges(lessons) do
    edges =
      Enum.map(lessons, fn lesson ->
        %{
          from_id: UUID.binary_to_string!(lesson.lesson_id),
          to_id: UUID.binary_to_string!(lesson.track_id),
          type: "BELONGS_TO",
          properties: %{}
        }
      end)

    case BotArmy.Graph.upsert_edges(edges) do
      {:ok, count} ->
        Logger.info("[Migration V004] Created #{count} BELONGS_TO edges")
        :ok

      {:error, e} ->
        Logger.error("[Migration V004] Failed to create edges", error: inspect(e))
        raise "Could not create BELONGS_TO edges: #{inspect(e)}"
    end
  end
end
