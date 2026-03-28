defmodule BotArmyTerrain.Ingestion.LessonDirectoryImporter do
  @moduledoc """
  Imports lessons from a directory structure:
  /path/to/lessons/
    ├── track_name_1/
    │   ├── npcs.yaml          (NPC definitions for the track)
    │   ├── lesson_1.yaml
    │   ├── lesson_2.yaml
    │   └── ...
    └── track_name_2/
        ├── npcs.yaml
        └── ...

  Each YAML file in a track directory becomes a lesson.
  """

  require Logger

  alias BotArmyTerrain.TrackStore
  alias BotArmyTerrain.LessonStore

  @doc """
  Imports all tracks and lessons from a directory.
  Returns {:ok, %{tracks_imported: n, lessons_imported: n}}
  or {:error, reason}
  """
  def import_directory(base_path) do
    case File.dir?(base_path) do
      false -> {:error, "Path is not a directory"}
      true -> do_import_directory(base_path)
    end
  end

  defp do_import_directory(base_path) do
    case File.ls(base_path) do
      {:ok, entries} ->
        track_dirs = Enum.filter(entries, &is_track_dir?(Path.join(base_path, &1)))

        results =
          Enum.map(track_dirs, fn track_dir_name ->
            track_dir_path = Path.join(base_path, track_dir_name)
            import_track_directory(track_dir_name, track_dir_path)
          end)

        # Count totals
        successful = Enum.filter(results, &match?({:ok, _}, &1))
        total_tracks = length(successful)

        total_lessons =
          successful
          |> Enum.map(fn {:ok, result} -> result.lessons_imported end)
          |> Enum.sum()

        Logger.info(
          "Terrain: imported #{total_tracks} track(s) with #{total_lessons} lesson(s)"
        )

        {:ok, %{tracks_imported: total_tracks, lessons_imported: total_lessons}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp is_track_dir?(path) do
    File.dir?(path) and not String.starts_with?(Path.basename(path), ".")
  end

  defp import_track_directory(track_name, track_dir_path) do
    track_name = String.replace(track_name, "_", " ") |> String.trim()

    with {:ok, track} <- TrackStore.get_or_create_track_by_name(track_name),
         {:ok, npcs} <- read_npcs(track_dir_path),
         {:ok, lesson_files} <- list_lesson_files(track_dir_path),
         {:ok, count} <- import_lessons(track, npcs, track_dir_path, lesson_files) do
      Logger.info("Terrain: imported track '#{track_name}' with #{count} lesson(s)")
      {:ok, %{track: track_name, lessons_imported: count}}
    else
      {:error, reason} ->
        Logger.error("Terrain: failed to import track #{track_name}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp read_npcs(track_dir_path) do
    npcs_path = Path.join(track_dir_path, "npcs.yaml")

    case File.exists?(npcs_path) do
      false ->
        {:ok, []}

      true ->
        case YamlElixir.read_from_file(npcs_path) do
          {:ok, data} -> {:ok, Map.get(data, "npc_players", [])}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp list_lesson_files(track_dir_path) do
    case File.ls(track_dir_path) do
      {:ok, entries} ->
        lesson_files =
          entries
          |> Enum.filter(fn file ->
            String.ends_with?(file, ".yaml") or String.ends_with?(file, ".yml")
          end)
          |> Enum.reject(fn file -> file == "npcs.yaml" end)

        {:ok, lesson_files}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp import_lessons(track, npcs, track_dir_path, lesson_files) do
    count =
      Enum.reduce(lesson_files, 0, fn lesson_file, acc ->
        lesson_path = Path.join(track_dir_path, lesson_file)

        case import_single_lesson(track, npcs, lesson_path) do
          :ok -> acc + 1
          :skip -> acc
        end
      end)

    {:ok, count}
  end

  defp import_single_lesson(track, npcs, lesson_path) do
    case YamlElixir.read_from_file(lesson_path) do
      {:ok, data} ->
        attrs = %{
          track_id: track.id,
          chunk_id: generate_chunk_id(lesson_path),
          title: Map.get(data, "title", "Untitled"),
          explanation: Map.get(data, "content", ""),
          external_link: Map.get(data, "external_link"),
          difficulty: Map.get(data, "difficulty", "intermediate"),
          quiz_question: Map.get(data, "quiz_question"),
          quiz_options: Map.get(data, "quiz_options", []),
          quiz_correct_index: Map.get(data, "quiz_correct_index"),
          host_intro: Map.get(data, "host_intro"),
          host_correct: Map.get(data, "host_correct"),
          host_wrong: Map.get(data, "host_wrong"),
          npc_players: Enum.map(npcs, &Map.get(&1, "name"))
        }

        case LessonStore.store_lesson(attrs) do
          {:ok, _} -> :ok
          {:error, reason} ->
            Logger.warning("Failed to create lesson from #{lesson_path}: #{inspect(reason)}")
            :skip
        end

      {:error, reason} ->
        Logger.warning("Failed to read YAML #{lesson_path}: #{inspect(reason)}")
        :skip
    end
  end

  defp generate_chunk_id(lesson_path) do
    # Generate a deterministic ID based on file path
    :crypto.hash(:sha256, lesson_path) |> Base.encode16(case: :lower) |> String.slice(0, 16)
  end
end
