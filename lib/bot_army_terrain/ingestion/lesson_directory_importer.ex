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
        # Check if this is a single track directory (contains .yaml/.yml files)
        # or a parent directory (contains subdirectories)
        has_yaml_files = Enum.any?(entries, fn entry ->
          String.ends_with?(entry, ".yaml") or String.ends_with?(entry, ".yml")
        end)

        if has_yaml_files do
          # Single track directory: use directory name as track name
          track_name = Path.basename(base_path)
          case import_track_directory(track_name, base_path) do
            {:ok, result} ->
              Logger.info(
                "Terrain: imported track '#{result.track}' with #{result.lessons_imported} lesson(s)"
              )
              {:ok, %{tracks_imported: 1, lessons_imported: result.lessons_imported}}

            {:error, reason} ->
              Logger.error("Terrain: failed to import track: #{inspect(reason)}")
              {:error, reason}
          end
        else
          # Parent directory: process all subdirectories as tracks
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
        end

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
      # Update chunk_count to reflect actual number of lessons/content chunks
      TrackStore.update_chunk_count_from_store(track.id)
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
        # Convert difficulty string to integer: beginner=1, intermediate=2, advanced=3
        difficulty =
          case Map.get(data, "difficulty", "intermediate") do
            "beginner" -> 1
            "intermediate" -> 2
            "advanced" -> 3
            num when is_integer(num) -> num
            _ -> 2
          end

        # Convert npc_players array to a map (npcs is already the array from read_npcs)
        npc_map =
          case npcs do
            players when is_list(players) ->
              Enum.reduce(players, %{}, fn player, acc ->
                if is_map(player) and Map.has_key?(player, "name") do
                  Map.put(acc, player["name"], player)
                else
                  acc
                end
              end)

            players when is_map(players) ->
              players

            _ ->
              %{}
          end

        quiz_payload = normalize_quiz_payload(data, difficulty)

        attrs = %{
          track_id: track.id,
          chunk_id: generate_chunk_id(lesson_path),
          title: Map.get(data, "title", "Untitled"),
          explanation: Map.get(data, "content", Map.get(data, "explanation", "")),
          external_link: Map.get(data, "external_link"),
          difficulty: difficulty,
          quiz_question: quiz_payload.quiz_question,
          quiz_options: quiz_payload.quiz_options,
          quiz_correct_index: quiz_payload.quiz_correct_index,
          quiz_questions: quiz_payload.quiz_questions,
          host_intro: Map.get(data, "host_intro"),
          host_correct: Map.get(data, "host_correct"),
          host_wrong: Map.get(data, "host_wrong"),
          npc_players: npc_map,
          generated_at: DateTime.utc_now(:microsecond)
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
    # Generate a deterministic UUID string based on file path
    # SHA256 hash, take first 16 bytes, format as UUID string (32+16+16+16+48 bits = 16 bytes)
    hash = :crypto.hash(:sha256, lesson_path)
    <<a::32, b::16, c::16, d::16, e::48>> = binary_part(hash, 0, 16)
    "#{Base.encode16(<<a::32>>, case: :lower)}-#{Base.encode16(<<b::16>>, case: :lower)}-#{Base.encode16(<<c::16>>, case: :lower)}-#{Base.encode16(<<d::16>>, case: :lower)}-#{Base.encode16(<<e::48>>, case: :lower)}"
  end

  defp normalize_quiz_payload(data, lesson_difficulty) do
    quiz_questions =
      case Map.get(data, "quiz_questions") do
        questions when is_list(questions) and questions != [] ->
          questions
          |> Enum.map(&normalize_quiz_question(&1, lesson_difficulty))
          |> Enum.reject(&is_nil/1)

        _ ->
          build_legacy_question(data, lesson_difficulty)
      end

    first = List.first(quiz_questions) || %{}

    %{
      quiz_question: Map.get(first, "question"),
      quiz_options: Map.get(first, "options", []),
      quiz_correct_index: Map.get(first, "correct_index"),
      quiz_questions: quiz_questions
    }
  end

  defp build_legacy_question(data, lesson_difficulty) do
    question = Map.get(data, "quiz_question")
    options = Map.get(data, "quiz_options", [])
    correct_index = Map.get(data, "quiz_correct_index")

    if is_binary(question) and is_list(options) and is_integer(correct_index) do
      [
        %{
          "question" => question,
          "options" => options,
          "correct_index" => correct_index,
          "difficulty" => lesson_difficulty
        }
      ]
    else
      []
    end
  end

  defp normalize_quiz_question(question, lesson_difficulty) when is_map(question) do
    stem = Map.get(question, "question")
    options = Map.get(question, "options", [])
    correct_index = Map.get(question, "correct_index")

    if is_binary(stem) and is_list(options) and is_integer(correct_index) do
      %{
        "question" => stem,
        "options" => options,
        "correct_index" => correct_index,
        "difficulty" => normalize_question_difficulty(Map.get(question, "difficulty"), lesson_difficulty)
      }
    else
      nil
    end
  end

  defp normalize_quiz_question(_, _), do: nil

  defp normalize_question_difficulty(value, _fallback) when is_integer(value) do
    cond do
      value < 1 -> 1
      value > 3 -> 3
      true -> value
    end
  end

  defp normalize_question_difficulty("beginner", _fallback), do: 1
  defp normalize_question_difficulty("intermediate", _fallback), do: 2
  defp normalize_question_difficulty("advanced", _fallback), do: 3
  defp normalize_question_difficulty(_, fallback), do: fallback
end
